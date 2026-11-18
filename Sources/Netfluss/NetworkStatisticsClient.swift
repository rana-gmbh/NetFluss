// Copyright (C) 2026 Rana GmbH
//
// This file is part of Netfluss.
//
// Netfluss is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Netfluss is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Netfluss. If not, see <https://www.gnu.org/licenses/>.

import Foundation
import Darwin

/// Per-flow byte counts from the kernel, at ~0% CPU: the system-wide inbound
/// rate for the macOS 26.5 `ifi_ibytes`-frozen workaround (issues #31 and #45),
/// and per-app rates for Top Apps.
///
/// `nettop` reads the same `com.apple.network.statistics` PF_SYSTEM kernel
/// control, but subscribes to its update firehose and costs >100% CPU on macOS
/// 27 however it is invoked. This client only *polls* the counters on a timer;
/// the continuous cost is draining a socket and summing a few hundred integers.
///
/// It replaces `netstat` for Top Apps too: on macOS 27.2.1 `netstat -n -b -v`
/// reports every TCP socket's rxbytes at twice the real value (txbytes are
/// right), while these per-flow counts match the interface counters.
///
/// Protocol (reverse-engineered; validated on macOS 26.5 and 27.2.1). The
/// message layout is private and may change between macOS releases, so all
/// parsing is offset- and length-guarded. A failed subscription is reported via
/// `subscriptionFailed`, and descriptors whose process name doesn't match the
/// process via `processAttributionFailed`, so the caller can fall back:
///   - Subscribe: NSTAT_MSG_TYPE_ADD_ALL_SRCS (56 bytes, provider u32 @ offset 32)
///     for the kernel TCP (2), user-space TCP (3) and kernel UDP (4) providers.
///     UDP carries QUIC, so a browser download over HTTP/3 is only seen there.
///   - Poll: NSTAT_MSG_TYPE_QUERY_SRC (24 bytes, srcref u64 @ offset 16 = ALL).
///   - Reply: NSTAT_MSG_TYPE_SRC_COUNTS messages (srcref @16, rxbytes @40,
///     txbytes @56), batched many-per-datagram and walked by the header `length`.
///   - Descriptor: NSTAT_MSG_TYPE_GET_SRC_DESC per srcref; the SRC_DESC reply
///     carries the provider @32 and, per provider, the interface index, the
///     owning PID and its process name (see `Layout`).
///
/// Per-flow lifetime byte counters are not monotonic across the source set
/// (a counter disappears when its flow closes), so we accumulate positive
/// per-`srcref` deltas and derive rates from them.
final class NetworkStatisticsClient {
    struct FlowCounts: Equatable, Sendable {
        var rx: UInt64
        var tx: UInt64
    }

    struct Endpoint: Equatable, Sendable {
        /// Numeric address; nil while unbound or unconnected (`*`).
        let host: String?
        let port: Int
    }

    struct FlowDescriptor: Equatable, Sendable {
        let provider: UInt32
        let ifindex: UInt32
        let pid: pid_t
        let processName: String
        var local: Endpoint? = nil
        var remote: Endpoint? = nil
        /// Resolved while the process is still alive: a short-lived flow's
        /// owner has often exited by the time its final counts are summed.
        var appName: String? = nil

        var protocolName: String { provider == NetworkStatisticsClient.providerUDPKernel ? "UDP" : "TCP" }
    }

    /// One connection's bytes in one poll interval, for the Network Slice.
    struct FlowSample: Equatable, Sendable {
        /// Stable across polls and client restarts: protocol, endpoints, PID.
        let id: String
        let appName: String
        let protocolName: String
        let local: Endpoint?
        let remote: Endpoint?
        let rx: UInt64
        let tx: UInt64
    }

    /// Who needs the client. It runs while anyone does, polls every second for
    /// the live consumers, and every 10 s when only the statistics need it:
    /// closed flows deliver their final counts themselves, so a slow poll
    /// loses no bytes.
    enum Demand: Hashable, Sendable {
        case rxFallback, topApps, statistics, networkSlice

        var isLive: Bool { self != .statistics }
        var needsOwners: Bool { self != .rxFallback }
    }

    /// Where a flow descriptor keeps its fields, by provider. Offsets are from
    /// the start of the SRC_DESC message (header included).
    struct Layout: Equatable {
        let ifindex: Int
        let pid: Int
        let processName: Int
        let processNameLength: Int
        /// sockaddr_in / sockaddr_in6 unions, 28 bytes each.
        let localAddress: Int
        let remoteAddress: Int

        /// nstat_tcp_descriptor, kernel and user-space TCP (400-byte message on 27.2.1).
        static let tcp = Layout(ifindex: 112, pid: 156, processName: 236, processNameLength: 64,
                                localAddress: 164, remoteAddress: 192)
        /// nstat_udp_descriptor (320-byte message on 27.2.1).
        static let udp = Layout(ifindex: 152, pid: 168, processName: 172, processNameLength: 64,
                                localAddress: 96, remoteAddress: 124)

        static func forProvider(_ provider: UInt32) -> Layout? {
            switch provider {
            case providerTCPKernel, providerTCPUserland: return .tcp
            case providerUDPKernel: return .udp
            default: return nil
            }
        }

        var minimumLength: Int { max(processName + 16, remoteAddress + 28) }
    }

    /// Called on the main queue once per poll with the total inbound rate
    /// (bytes/sec, summed across all non-loopback flows) and a per-interface
    /// breakdown keyed by BSD name (e.g. "en0"). Flows whose interface hasn't
    /// been resolved yet are absent from the breakdown but still in the total.
    var onSample: ((_ totalRxRateBps: Double, _ ratesByInterface: [String: Double], _ at: Date) -> Void)?

    /// Called on the main queue once per poll while Top Apps is a demand, with
    /// per-app rates sorted by total traffic. Flows whose owner isn't known
    /// yet are left out until their descriptor arrives.
    var onAppSample: ((_ apps: [AppTraffic], _ at: Date) -> Void)?

    /// Called on the main queue once per poll while the Network Slice is a
    /// demand, with every connection that moved bytes and the interval length.
    var onFlowSample: ((_ flows: [FlowSample], _ elapsed: TimeInterval, _ at: Date) -> Void)?

    /// `true` if the kernel rejected a subscription or counts query (e.g. the
    /// private message layout changed). The caller should fall back to
    /// `netstat` diffs when this is observed. Thread-safe.
    var subscriptionFailed: Bool { queue.sync { _subscriptionFailed } }
    private var _subscriptionFailed = false

    /// `true` once descriptors proved not to carry the owning process where
    /// `Layout` expects it (their process name didn't match the PID's). Top
    /// Apps should then use `netstat`. Survives restarts. Thread-safe.
    var processAttributionFailed: Bool { queue.sync { _attributionFailed } }
    private var _attributionFailed = false
    private var layoutChecks = 0
    private var layoutMatches = 0
    private var layoutVerified = false
    private static let layoutCheckCount = 10

    /// False once the client can't serve per-app data: the subscription
    /// failed, or descriptors don't carry the owner on this macOS. Consumers
    /// then use `netstat`. Thread-safe.
    var canAttributeApps: Bool { queue.sync { !_subscriptionFailed && !_attributionFailed } }

    private var demands: Set<Demand> = []
    private var needsOwners: Bool { !_attributionFailed && demands.contains { $0.needsOwners } }
    /// Per-app bytes since the statistics last collected them.
    private var pendingAppTotals: [String: FlowCounts] = [:]
    private var pollIntervalInUse: TimeInterval = 0

    private let queue = DispatchQueue(label: "com.local.netfluss.netstat", qos: .utility)
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var pollTimer: DispatchSourceTimer?
    private var running = false

    // Per-srcref counts at the previous poll and as received since.
    private var lastCounts: [UInt64: FlowCounts] = [:]
    private var currentCounts: [UInt64: FlowCounts] = [:]
    private var baselined = false
    /// Polls that saw counts before `baselined`. The reply to the first query
    /// can straddle a poll, so one poll with counts is not yet a full table.
    private var warmupPolls = 0
    private static let warmupPollCount = 2
    private var lastPollAt: Date?
    private var readBuffer = [UInt8](repeating: 0, count: 1 << 18)

    // Flow owner and interface, resolved lazily via GET_SRC_DESC. Requests are
    // spread over polls and retried: sent all at once, most replies are dropped
    // for lack of buffer space.
    private var descriptors: [UInt64: FlowDescriptor] = [:]
    private var descRequestedAt: [UInt64: Date] = [:]
    /// Bytes of flows whose owner wasn't known yet, handed to the app once it
    /// is: browsers open many short connections, so dropping a flow's first
    /// second loses much of their traffic.
    private var unattributed: [UInt64: FlowCounts] = [:]
    /// Flows the kernel reported closed since the last poll. Their final counts
    /// are still folded in once before they are forgotten.
    private var removedSrcrefs: Set<UInt64> = []
    /// Network Slice bytes of TCP flows whose descriptor has no remote address
    /// yet, emitted once it has one: otherwise a connection would show up as
    /// one row under "*" and another under its host.
    private var heldFlowBytes: [UInt64: FlowCounts] = [:]
    private var ifNameCache: [UInt32: String] = [:]
    private let loopbackIndex = if_nametoindex("lo0")
    private static let descriptorRequestsPerPoll = 64
    private static let descriptorRetryInterval: TimeInterval = 3
    private static let addresslessRetryInterval: TimeInterval = 0.9

    // MARK: ntstat protocol constants
    private static let controlName = "com.apple.network.statistics"
    // _IOWR('N', 3, struct ctl_info): sizeof(ctl_info) = 4 + 96 = 100.
    private static let CTLIOCGINFO: UInt = 0xC0000000 | ((100 & 0x1fff) << 16) | (UInt(UInt8(ascii: "N")) << 8) | 3
    private static let MSG_ADD_ALL_SRCS: UInt32 = 1002
    private static let MSG_QUERY_SRC: UInt32 = 1004
    private static let MSG_GET_SRC_DESC: UInt32 = 1005
    private static let MSG_SRC_REMOVED: UInt32 = 10002
    private static let MSG_SRC_DESC: UInt32 = 10003
    private static let MSG_SRC_COUNTS: UInt32 = 10004
    private static let MSG_SRC_UPDATE: UInt32 = 10005
    private static let MSG_ERROR: UInt32 = 1
    static let providerTCPKernel: UInt32 = 2
    static let providerTCPUserland: UInt32 = 3
    static let providerUDPKernel: UInt32 = 4
    private static let srcRefAll: UInt64 = .max
    private static let livePollInterval: TimeInterval = 1
    private static let statisticsPollInterval: TimeInterval = 10
    private static let receiveBufferSize: Int32 = 1 << 20

    var isRunning: Bool { queue.sync { running } }

    /// Registers or withdraws a consumer; starts or stops the client to match.
    func setDemand(_ demand: Demand, _ active: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let changed = active ? self.demands.insert(demand).inserted : self.demands.remove(demand) != nil
            guard changed else { return }
            if demand == .statistics, !active { self.pendingAppTotals.removeAll() }
            if self.demands.isEmpty {
                self.stopLocked()
            } else if self.fd < 0 {
                self.startLocked()
            } else {
                self.schedulePolls()
            }
        }
    }

    /// Per-app bytes since the last call, for the app statistics.
    func takeAppTotals() -> [String: FlowCounts] {
        queue.sync {
            let totals = pendingAppTotals
            pendingAppTotals.removeAll(keepingCapacity: true)
            return totals
        }
    }

    // MARK: - Lifecycle

    private func startLocked() {
        // A rejected subscription stays rejected for the session; consumers
        // have switched to netstat by then.
        guard fd < 0, !_subscriptionFailed else { return }

        let sock = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard sock >= 0 else { _subscriptionFailed = true; return }

        var info = ctl_info()
        _ = withUnsafeMutablePointer(to: &info.ctl_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 96) { dst in
                Self.controlName.withCString { strcpy(dst, $0) }
            }
        }
        guard ioctl(sock, Self.CTLIOCGINFO, &info) == 0 else {
            close(sock); _subscriptionFailed = true; return
        }

        var addr = sockaddr_ctl()
        addr.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        addr.sc_family = UInt8(AF_SYSTEM)
        addr.ss_sysaddr = UInt16(AF_SYS_CONTROL)
        addr.sc_id = info.ctl_id
        addr.sc_unit = 0
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_ctl>.size))
            }
        }
        guard rc == 0 else { close(sock); _subscriptionFailed = true; return }

        // Non-blocking so the read source can drain without blocking the queue.
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        // Room for a full counts reply: a busy Mac has hundreds of flows.
        var bufferSize = Self.receiveBufferSize
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))

        fd = sock
        resetFlowState()

        for provider in [Self.providerTCPKernel, Self.providerTCPUserland, Self.providerUDPKernel] {
            subscribe(provider: provider)
        }
        if _subscriptionFailed { stopLocked(); return }

        let rs = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        rs.setEventHandler { [weak self] in self?.drainLocked() }
        rs.resume()
        readSource = rs

        // Ask for counts now, so the first poll can take its baseline from them.
        query()

        running = true
        schedulePolls()
    }

    /// Fast polls until the baseline stands and while a live consumer needs
    /// them; slow ones when only the statistics do.
    private func schedulePolls() {
        guard fd >= 0 else { return }
        let live = !baselined || demands.contains { $0.isLive }
        let interval = live ? Self.livePollInterval : Self.statisticsPollInterval
        guard pollTimer == nil || interval != pollIntervalInUse else { return }
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let leeway = DispatchTimeInterval.milliseconds(Int(interval * 200))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        timer.setEventHandler { [weak self] in self?.pollLocked() }
        timer.resume()
        pollTimer = timer
        pollIntervalInUse = interval
    }

    private func stopLocked() {
        pollTimer?.cancel(); pollTimer = nil
        pollIntervalInUse = 0
        readSource?.cancel(); readSource = nil
        if fd >= 0 { close(fd); fd = -1 }
        resetFlowState()
        running = false
    }

    private func resetFlowState() {
        lastCounts.removeAll(keepingCapacity: false)
        currentCounts.removeAll(keepingCapacity: false)
        descriptors.removeAll(keepingCapacity: false)
        descRequestedAt.removeAll(keepingCapacity: false)
        unattributed.removeAll(keepingCapacity: false)
        removedSrcrefs.removeAll(keepingCapacity: false)
        heldFlowBytes.removeAll(keepingCapacity: false)
        baselined = false
        warmupPolls = 0
        lastPollAt = nil
    }

    // MARK: - Messaging

    private func subscribe(provider: UInt32) {
        var msg = [UInt8](repeating: 0, count: 56)
        writeU64(&msg, UInt64(Self.MSG_ADD_ALL_SRCS), at: 0) // echoed in error replies
        writeU32(&msg, Self.MSG_ADD_ALL_SRCS, at: 8)   // hdr.type
        writeU16(&msg, 56, at: 12)                     // hdr.length
        writeU32(&msg, provider, at: 32)               // provider
        send(msg)
    }

    private func query() {
        var msg = [UInt8](repeating: 0, count: 24)
        writeU64(&msg, UInt64(Self.MSG_QUERY_SRC), at: 0)
        writeU32(&msg, Self.MSG_QUERY_SRC, at: 8)
        writeU16(&msg, 24, at: 12)
        writeU64(&msg, Self.srcRefAll, at: 16)         // srcref = ALL
        send(msg)
    }

    /// Ask the kernel for a single flow's descriptor (owner and interface).
    private func requestDescriptor(_ srcref: UInt64) {
        var msg = [UInt8](repeating: 0, count: 24)
        writeU64(&msg, UInt64(Self.MSG_GET_SRC_DESC), at: 0)
        writeU32(&msg, Self.MSG_GET_SRC_DESC, at: 8)
        writeU16(&msg, 24, at: 12)
        writeU64(&msg, srcref, at: 16)
        send(msg)
    }

    /// Resolve and cache an ifindex to its BSD interface name; nil if it does
    /// not map to a real interface (guards against a wrong descriptor offset
    /// on a future macOS — bad data simply won't be attributed).
    private func interfaceName(for ifindex: UInt32) -> String? {
        if let cached = ifNameCache[ifindex] { return cached.isEmpty ? nil : cached }
        var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        let name = if_indextoname(ifindex, &buf).map { String(cString: $0) }
        ifNameCache[ifindex] = name ?? ""
        return name
    }

    private func send(_ bytes: [UInt8]) {
        guard fd >= 0 else { return }
        let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, bytes.count, 0) }
        if n < 0 {
            let sendError = errno
            if Self.errorRequiresFallback(context: readU64(bytes, 0), error: sendError) {
                _subscriptionFailed = true
            }
        }
    }

    /// A descriptor only enriches attribution; losing a source while looking it
    /// up (ENOENT), or failing to enqueue its reply (ENOBUFS), does not
    /// invalidate the subscriptions or the system-wide byte counts. Polls retry
    /// transient failures next tick. Subscriptions are sent once, so a rejected
    /// subscription must still activate the fallback.
    static func errorRequiresFallback(context: UInt64, error: Int32) -> Bool {
        if context == UInt64(MSG_GET_SRC_DESC) { return false }
        if context == UInt64(MSG_QUERY_SRC), error == ENOBUFS || error == EAGAIN {
            return false
        }
        return true
    }

    // MARK: - Receive

    private func drainLocked() {
        guard fd >= 0 else { return }
        while true {
            let n = recv(fd, &readBuffer, readBuffer.count, 0)
            if n <= 0 { break }
            parse(count: n)
            if n < readBuffer.count { break }
        }
    }

    /// Walk the (possibly batched) datagram by header `length`, recording the
    /// latest counts per srcref and noting removed sources.
    private func parse(count n: Int) {
        var off = 0
        while off + 16 <= n {
            let type = readU32(readBuffer, off + 8)
            let len = Int(readU16(readBuffer, off + 12))
            if len < 16 || off + len > n { break }
            switch type {
            case Self.MSG_SRC_COUNTS, Self.MSG_SRC_UPDATE:
                // srcref @ +16, nstat_counts @ +32 (rxbytes @+40, txbytes @+56)
                if len >= 64 {
                    let srcref = readU64(readBuffer, off + 16)
                    currentCounts[srcref] = FlowCounts(
                        rx: readU64(readBuffer, off + 40),
                        tx: readU64(readBuffer, off + 56)
                    )
                    requestDescriptorIfNew(srcref)
                }
            case Self.MSG_SRC_DESC:
                if var descriptor = Self.parseDescriptor(readBuffer, at: off, length: len) {
                    let srcref = readU64(readBuffer, off + 16)
                    verifyLayout(with: descriptor)
                    if needsOwners, descriptor.pid > 0 {
                        descriptor.appName = descriptors[srcref]?.appName ?? appName(for: descriptor)
                    }
                    descriptors[srcref] = descriptor
                }
            case Self.MSG_SRC_REMOVED:
                removedSrcrefs.insert(readU64(readBuffer, off + 16))
            case Self.MSG_ERROR:
                // nstat_msg_error is a 16-byte header, errno and 4 reserved
                // bytes. Do not read past a truncated error into the next frame.
                if len >= 24,
                   Self.errorRequiresFallback(
                       context: readU64(readBuffer, off),
                       error: Int32(bitPattern: readU32(readBuffer, off + 16))
                   ) {
                    _subscriptionFailed = true
                }
            default:
                break
            }
            off += len
        }
    }

    /// Once the baseline stands, a new flow's owner is asked for as soon as its
    /// first counts arrive, so it is known by the next poll. (Asking when the
    /// flow is added is too early: a TCP client has no addresses before it
    /// connects.) Before that, the flows that were already
    /// open are requested a batch per poll; all at once, most replies would be
    /// dropped.
    private func requestDescriptorIfNew(_ srcref: UInt64) {
        guard baselined, descriptors[srcref] == nil, descRequestedAt[srcref] == nil else { return }
        descRequestedAt[srcref] = Date()
        requestDescriptor(srcref)
    }

    /// Decodes a SRC_DESC message starting at `offset`. Nil for providers
    /// without a known layout and for messages too short for it.
    static func parseDescriptor(_ bytes: [UInt8], at offset: Int = 0, length: Int) -> FlowDescriptor? {
        guard length >= 40, offset + length <= bytes.count else { return nil }
        let provider = readU32(bytes, offset + 32)
        guard let layout = Layout.forProvider(provider), length >= layout.minimumLength else { return nil }
        let nameStart = offset + layout.processName
        let nameEnd = min(nameStart + layout.processNameLength, offset + length)
        let nameBytes = bytes[nameStart..<nameEnd].prefix { $0 != 0 }
        return FlowDescriptor(
            provider: provider,
            ifindex: readU32(bytes, offset + layout.ifindex),
            pid: pid_t(bitPattern: readU32(bytes, offset + layout.pid)),
            processName: String(decoding: nameBytes, as: UTF8.self),
            local: endpoint(bytes, at: offset + layout.localAddress),
            remote: endpoint(bytes, at: offset + layout.remoteAddress)
        )
    }

    /// Decodes a sockaddr_in / sockaddr_in6. Nil for anything else (a moved
    /// layout reads as no address rather than a wrong one).
    static func endpoint(_ bytes: [UInt8], at offset: Int) -> Endpoint? {
        guard offset >= 0, offset + 28 <= bytes.count else { return nil }
        let length = Int(bytes[offset])
        let family = Int32(bytes[offset + 1])
        let port = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let address: [UInt8]
        switch family {
        case AF_INET where length == MemoryLayout<sockaddr_in>.size:
            address = Array(bytes[(offset + 4)..<(offset + 8)])
        case AF_INET6 where length == MemoryLayout<sockaddr_in6>.size:
            address = Array(bytes[(offset + 8)..<(offset + 24)])
        default:
            return nil
        }
        guard address.withUnsafeBytes({ inet_ntop(family, $0.baseAddress, &text, socklen_t(text.count)) }) != nil else {
            return nil
        }
        let unbound = address.allSatisfy { $0 == 0 }
        return Endpoint(host: unbound ? nil : String(cString: text), port: port)
    }

    /// Both ends on 127.0.0.0/8 or ::1, as a fallback when a flow's
    /// interface isn't known.
    static func isLoopback(_ endpoint: Endpoint?) -> Bool {
        guard let host = endpoint?.host else { return false }
        return host.hasPrefix("127.") || host == "::1"
    }

    /// Whether a descriptor's process name agrees with what the kernel reports
    /// for its PID. The descriptor may hold the short `p_comm` (16 bytes) or
    /// the longer `p_name`, so either may be a prefix of the other.
    static func processNamesAgree(descriptor: String, actual: String) -> Bool {
        guard !descriptor.isEmpty, !actual.isEmpty else { return false }
        let a = descriptor.prefix(15)
        let b = actual.prefix(15)
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Checks the first descriptors against `proc_name`; if most disagree, the
    /// layout has moved on this macOS and no PID from it can be trusted.
    private func verifyLayout(with descriptor: FlowDescriptor) {
        guard !layoutVerified, !_attributionFailed, descriptor.pid > 0 else { return }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(descriptor.pid, &buffer, UInt32(buffer.count)) > 0 else { return }
        let actual = String(cString: buffer)
        layoutChecks += 1
        if Self.processNamesAgree(descriptor: descriptor.processName, actual: actual) {
            layoutMatches += 1
        }
        guard layoutChecks >= Self.layoutCheckCount else { return }
        if layoutMatches * 10 >= layoutChecks * 7 {
            layoutVerified = true
        } else {
            _attributionFailed = true
            descriptors.removeAll(keepingCapacity: false)
        }
    }

    // MARK: - Poll / accumulate

    private func pollLocked() {
        let now = Date()
        let resolveOwners = needsOwners
        let wantFlows = resolveOwners && demands.contains(.networkSlice) && onFlowSample != nil
        var intervalRx: UInt64 = 0
        var intervalRxByIf: [UInt32: UInt64] = [:]
        var appDeltas: [String: (rx: UInt64, tx: UInt64)] = [:]
        var flows: [FlowSample] = []
        var unresolved: [(srcref: UInt64, bytes: UInt64)] = []
        var addressless: [(srcref: UInt64, bytes: UInt64)] = []

        if resolveOwners { ProcessNetworkSampler.clearNameCacheIfNeeded() }
        for (ref, counts) in currentCounts {
            let delta = Self.flowDelta(current: counts, previous: lastCounts[ref])
            guard let descriptor = descriptors[ref] else {
                unresolved.append((ref, delta.rx &+ delta.tx))
                // Owner unknown: the total gets the bytes now, the app later.
                intervalRx &+= delta.rx
                if baselined, delta.rx > 0 || delta.tx > 0 {
                    let held = unattributed[ref] ?? FlowCounts(rx: 0, tx: 0)
                    unattributed[ref] = FlowCounts(rx: held.rx &+ delta.rx, tx: held.tx &+ delta.tx)
                }
                continue
            }
            let held = unattributed.removeValue(forKey: ref) ?? FlowCounts(rx: 0, tx: 0)
            // Local IPC is not network traffic, and lo0 is not in the totals (#54).
            if descriptor.ifindex == loopbackIndex
                || (Self.isLoopback(descriptor.local) && Self.isLoopback(descriptor.remote)) { continue }
            guard delta.rx > 0 || delta.tx > 0 || held.rx > 0 || held.tx > 0 else { continue }
            intervalRx &+= delta.rx
            if delta.rx > 0 {
                intervalRxByIf[descriptor.ifindex, default: 0] &+= delta.rx
            }
            guard resolveOwners, descriptor.pid > 0 else { continue }
            let name = descriptor.appName ?? appName(for: descriptor)
            let rx = delta.rx &+ held.rx
            let tx = delta.tx &+ held.tx
            let existing = appDeltas[name] ?? (rx: 0, tx: 0)
            appDeltas[name] = (existing.rx &+ rx, existing.tx &+ tx)
            if descriptor.protocolName == "TCP", descriptor.remote?.host == nil {
                // Described before it connected: ask again for the addresses.
                addressless.append((ref, rx &+ tx))
                if wantFlows {
                    let flowHeld = heldFlowBytes[ref] ?? FlowCounts(rx: 0, tx: 0)
                    heldFlowBytes[ref] = FlowCounts(rx: flowHeld.rx &+ rx, tx: flowHeld.tx &+ tx)
                }
                continue
            }
            if wantFlows {
                let flowHeld = heldFlowBytes.removeValue(forKey: ref) ?? FlowCounts(rx: 0, tx: 0)
                flows.append(FlowSample(
                    id: Self.flowID(descriptor),
                    appName: name,
                    protocolName: descriptor.protocolName,
                    local: descriptor.local,
                    remote: descriptor.remote,
                    rx: rx &+ flowHeld.rx,
                    tx: tx &+ flowHeld.tx
                ))
            }
        }
        lastCounts = currentCounts
        for ref in removedSrcrefs {
            currentCounts.removeValue(forKey: ref)
            lastCounts.removeValue(forKey: ref)
            descriptors.removeValue(forKey: ref)
            descRequestedAt.removeValue(forKey: ref)
            unattributed.removeValue(forKey: ref)
            heldFlowBytes.removeValue(forKey: ref)
        }
        removedSrcrefs.removeAll(keepingCapacity: true)

        if baselined {
            let elapsed = max(now.timeIntervalSince(lastPollAt ?? now), 0.001)
            let totalRate = Double(intervalRx) / elapsed
            var ratesByName: [String: Double] = [:]
            for (ifindex, bytes) in intervalRxByIf {
                guard let name = interfaceName(for: ifindex) else { continue }
                ratesByName[name] = Double(bytes) / elapsed
            }
            if demands.contains(.rxFallback), let onSample {
                DispatchQueue.main.async { onSample(totalRate, ratesByName, now) }
            }
            if resolveOwners, demands.contains(.topApps), let onAppSample {
                let apps = ProcessNetworkSampler.rates(from: appDeltas, elapsed: elapsed, limit: .max)
                DispatchQueue.main.async { onAppSample(apps, now) }
            }
            if wantFlows, let onFlowSample {
                DispatchQueue.main.async { onFlowSample(flows, elapsed, now) }
            }
            if resolveOwners, demands.contains(.statistics) {
                for (name, delta) in appDeltas {
                    let total = pendingAppTotals[name] ?? FlowCounts(rx: 0, tx: 0)
                    pendingAppTotals[name] = FlowCounts(rx: total.rx &+ delta.rx, tx: total.tx &+ delta.tx)
                }
            }
        } else if !currentCounts.isEmpty {
            // The first polls with counts only establish per-flow baselines
            // (existing flows already carry lifetime bytes we must not count as
            // just-received). Baselining an empty or half-filled table made the
            // next poll count the lifetime bytes of every flow it had missed: a
            // one-off spike of 100+ MB/s that went into the statistics.
            warmupPolls += 1
            baselined = warmupPolls >= Self.warmupPollCount
            if baselined { schedulePolls() }
        }
        lastPollAt = now

        // Request fresh counts for the next interval.
        query()
        requestDescriptors(for: unresolved, retryAfter: Self.descriptorRetryInterval, at: now)
        requestDescriptors(for: addressless, retryAfter: Self.addresslessRetryInterval, at: now)
    }

    static func flowID(_ descriptor: FlowDescriptor) -> String {
        func text(_ endpoint: Endpoint?) -> String {
            guard let endpoint else { return "?" }
            return "\(endpoint.host ?? "*").\(endpoint.port)"
        }
        return [descriptor.protocolName, text(descriptor.local), text(descriptor.remote), String(descriptor.pid)]
            .joined(separator: "|")
    }

    /// The app a flow belongs to, as Top Apps names it; the descriptor's own
    /// process name once the process is gone.
    private func appName(for descriptor: FlowDescriptor) -> String {
        let name = ProcessNetworkSampler.cachedProcessName(for: descriptor.pid)
        if name.hasPrefix("PID "), !descriptor.processName.isEmpty {
            return descriptor.processName
        }
        return name
    }

    /// Asks for the descriptors still missing, busiest flows first, a bounded
    /// number per poll.
    private func requestDescriptors(
        for unresolved: [(srcref: UInt64, bytes: UInt64)],
        retryAfter retryInterval: TimeInterval,
        at now: Date
    ) {
        guard !unresolved.isEmpty else { return }
        var sent = 0
        for flow in unresolved.sorted(by: { $0.bytes > $1.bytes }) {
            if let at = descRequestedAt[flow.srcref], now.timeIntervalSince(at) < retryInterval {
                continue
            }
            descRequestedAt[flow.srcref] = now
            requestDescriptor(flow.srcref)
            sent += 1
            if sent >= Self.descriptorRequestsPerPoll { break }
        }
    }

    /// Bytes a flow moved since the previous poll. A flow seen for the first
    /// time after the baseline is new, so all of its bytes count; a smaller
    /// counter means the srcref was reused for a new flow.
    static func flowDelta(current: FlowCounts, previous: FlowCounts?) -> FlowCounts {
        guard let previous else { return current }
        return FlowCounts(
            rx: current.rx >= previous.rx ? current.rx - previous.rx : current.rx,
            tx: current.tx >= previous.tx ? current.tx - previous.tx : current.tx
        )
    }

    // MARK: - Little-endian helpers

    private func writeU16(_ b: inout [UInt8], _ v: UInt16, at o: Int) { for i in 0..<2 { b[o+i] = UInt8((v >> (8*i)) & 0xff) } }
    private func writeU32(_ b: inout [UInt8], _ v: UInt32, at o: Int) { for i in 0..<4 { b[o+i] = UInt8((v >> (8*i)) & 0xff) } }
    private func writeU64(_ b: inout [UInt8], _ v: UInt64, at o: Int) { for i in 0..<8 { b[o+i] = UInt8((v >> (8*i)) & 0xff) } }
    private func readU16(_ b: [UInt8], _ o: Int) -> UInt16 { o+2 <= b.count ? UInt16(b[o]) | (UInt16(b[o+1]) << 8) : 0 }
    private func readU32(_ b: [UInt8], _ o: Int) -> UInt32 { Self.readU32(b, o) }
    private func readU64(_ b: [UInt8], _ o: Int) -> UInt64 {
        guard o >= 0, o+8 <= b.count else { return 0 }
        var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(b[o+i]) << (8*i) }; return v
    }
    private static func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o >= 0, o+4 <= b.count else { return 0 }
        var v: UInt32 = 0; for i in 0..<4 { v |= UInt32(b[o+i]) << (8*i) }; return v
    }
}
