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

/// Low-overhead system-wide inbound byte-rate source for the macOS 26.5
/// `ifi_ibytes`-frozen workaround (issues #31 and #45).
///
/// Instead of running `nettop` continuously — which subscribes to the kernel's
/// per-flow statistics firehose and costs >100% CPU on a busy machine — this
/// talks to the same `com.apple.network.statistics` PF_SYSTEM kernel control
/// directly, but only *polls* per-flow counters on a timer. The continuous cost
/// is just draining a socket and summing a few hundred integers, which measures
/// at ~0% CPU.
///
/// Protocol (reverse-engineered and validated on macOS 26.5; the message layout
/// is private and may change between macOS releases, so all parsing is offset-
/// and length-guarded and a failed subscription is reported via `subscriptionFailed`
/// so the caller can fall back to `nettop`):
///   - Subscribe: NSTAT_MSG_TYPE_ADD_ALL_SRCS (56 bytes, provider u32 @ offset 32)
///     for the TCP and UDP flow providers.
///   - Poll: NSTAT_MSG_TYPE_QUERY_SRC (24 bytes, srcref u64 @ offset 16 = ALL).
///   - Reply: NSTAT_MSG_TYPE_SRC_COUNTS messages (srcref @16, rxbytes @40),
///     batched many-per-datagram and walked by the header `length` field.
///
/// Per-flow lifetime byte counters are not monotonic across the source set
/// (a counter disappears when its flow closes), so we accumulate positive
/// per-`srcref` deltas into a monotonic inbound total and derive the rate.
final class NetworkStatisticsClient {
    /// Called on the main queue once per poll with the smoothed inbound rate
    /// (bytes/sec) and the monotonic cumulative inbound byte total.
    var onSample: ((_ rxRateBps: Double, _ cumulativeRxBytes: UInt64, _ at: Date) -> Void)?

    /// `true` if the kernel rejected our subscription (e.g. the private message
    /// layout changed on a future macOS). The caller should fall back to the
    /// `nettop`-based collector when this is observed. Thread-safe.
    var subscriptionFailed: Bool { queue.sync { _subscriptionFailed } }
    private var _subscriptionFailed = false

    private let queue = DispatchQueue(label: "com.local.netfluss.netstat", qos: .utility)
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var pollTimer: DispatchSourceTimer?
    private var running = false

    // Per-srcref last-seen rxbytes, and the monotonic accumulator.
    private var lastRxBySrc: [UInt64: UInt64] = [:]
    private var currentRxBySrc: [UInt64: UInt64] = [:]
    private var cumulativeRx: UInt64 = 0
    private var baselined = false
    private var lastPollAt: Date?
    private var readBuffer = [UInt8](repeating: 0, count: 1 << 18)

    // MARK: ntstat protocol constants
    private static let controlName = "com.apple.network.statistics"
    // _IOWR('N', 3, struct ctl_info): sizeof(ctl_info) = 4 + 96 = 100.
    private static let CTLIOCGINFO: UInt = 0xC0000000 | ((100 & 0x1fff) << 16) | (UInt(UInt8(ascii: "N")) << 8) | 3
    private static let MSG_ADD_ALL_SRCS: UInt32 = 1002
    private static let MSG_QUERY_SRC: UInt32 = 1004
    private static let MSG_SRC_REMOVED: UInt32 = 10002
    private static let MSG_SRC_COUNTS: UInt32 = 10004
    private static let MSG_SRC_UPDATE: UInt32 = 10005
    private static let MSG_ERROR: UInt32 = 1
    private static let providerTCP: UInt32 = 2
    private static let providerUDP: UInt32 = 3
    private static let srcRefAll: UInt64 = .max
    private static let pollInterval: TimeInterval = 1.0

    var isRunning: Bool { queue.sync { running } }

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    func stop() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    // MARK: - Lifecycle

    private func startLocked() {
        guard fd < 0 else { return }
        _subscriptionFailed = false

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

        fd = sock
        lastRxBySrc.removeAll(keepingCapacity: false)
        currentRxBySrc.removeAll(keepingCapacity: false)
        cumulativeRx = 0
        baselined = false
        lastPollAt = nil

        // Subscribe to the TCP and UDP flow providers.
        subscribe(provider: Self.providerTCP)
        subscribe(provider: Self.providerUDP)
        if _subscriptionFailed { stopLocked(); return }

        let rs = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        rs.setEventHandler { [weak self] in self?.drainLocked() }
        rs.resume()
        readSource = rs

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.pollLocked() }
        timer.resume()
        pollTimer = timer

        running = true
    }

    private func stopLocked() {
        pollTimer?.cancel(); pollTimer = nil
        readSource?.cancel(); readSource = nil
        if fd >= 0 { close(fd); fd = -1 }
        lastRxBySrc.removeAll(keepingCapacity: false)
        currentRxBySrc.removeAll(keepingCapacity: false)
        cumulativeRx = 0
        baselined = false
        lastPollAt = nil
        running = false
    }

    // MARK: - Messaging

    private func subscribe(provider: UInt32) {
        var msg = [UInt8](repeating: 0, count: 56)
        writeU32(&msg, Self.MSG_ADD_ALL_SRCS, at: 8)   // hdr.type
        writeU16(&msg, 56, at: 12)                     // hdr.length
        writeU32(&msg, provider, at: 32)               // provider
        send(msg)
    }

    private func query() {
        var msg = [UInt8](repeating: 0, count: 24)
        writeU32(&msg, Self.MSG_QUERY_SRC, at: 8)
        writeU16(&msg, 24, at: 12)
        writeU64(&msg, Self.srcRefAll, at: 16)         // srcref = ALL
        send(msg)
    }

    private func send(_ bytes: [UInt8]) {
        guard fd >= 0 else { return }
        let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, bytes.count, 0) }
        // ENOBUFS/EAGAIN on a request is non-fatal; the next poll retries.
        if n < 0 && errno == EINVAL {
            // Kernel rejected a request outright — treat as a layout mismatch.
            _subscriptionFailed = true
        }
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
    /// latest rxbytes per srcref and dropping removed sources.
    private func parse(count n: Int) {
        var off = 0
        while off + 16 <= n {
            let type = readU32(readBuffer, off + 8)
            let len = Int(readU16(readBuffer, off + 12))
            if len < 16 || off + len > n { break }
            switch type {
            case Self.MSG_SRC_COUNTS, Self.MSG_SRC_UPDATE:
                // srcref @ +16, nstat_counts @ +32 (rxpackets @+32, rxbytes @+40)
                if len >= 48 {
                    let srcref = readU64(readBuffer, off + 16)
                    let rxbytes = readU64(readBuffer, off + 40)
                    currentRxBySrc[srcref] = rxbytes
                }
            case Self.MSG_SRC_REMOVED:
                let srcref = readU64(readBuffer, off + 16)
                currentRxBySrc.removeValue(forKey: srcref)
                lastRxBySrc.removeValue(forKey: srcref)
            case Self.MSG_ERROR:
                _subscriptionFailed = true
            default:
                break
            }
            off += len
        }
    }

    // MARK: - Poll / accumulate

    private func pollLocked() {
        // Fold the counts received since the previous poll into a monotonic total.
        let now = Date()
        var intervalRx: UInt64 = 0
        for (ref, bytes) in currentRxBySrc {
            let prev = lastRxBySrc[ref] ?? 0
            // New or grown flow → count the gain. A smaller value means the
            // srcref was reused for a new flow, so count it from zero.
            intervalRx &+= bytes >= prev ? (bytes - prev) : bytes
        }
        lastRxBySrc = currentRxBySrc

        if baselined {
            cumulativeRx &+= intervalRx
            let elapsed = max(now.timeIntervalSince(lastPollAt ?? now), 0.001)
            let rate = Double(intervalRx) / elapsed
            let total = cumulativeRx
            if let onSample {
                DispatchQueue.main.async { onSample(rate, total, now) }
            }
        } else {
            // First poll only establishes per-flow baselines (existing flows
            // already carry lifetime bytes we must not count as just-received).
            baselined = true
        }
        lastPollAt = now

        // Request fresh counts for the next interval.
        query()
    }

    // MARK: - Little-endian helpers

    private func writeU16(_ b: inout [UInt8], _ v: UInt16, at o: Int) { for i in 0..<2 { b[o+i] = UInt8((v >> (8*i)) & 0xff) } }
    private func writeU32(_ b: inout [UInt8], _ v: UInt32, at o: Int) { for i in 0..<4 { b[o+i] = UInt8((v >> (8*i)) & 0xff) } }
    private func writeU64(_ b: inout [UInt8], _ v: UInt64, at o: Int) { for i in 0..<8 { b[o+i] = UInt8((v >> (8*i)) & 0xff) } }
    private func readU16(_ b: [UInt8], _ o: Int) -> UInt16 { o+2 <= b.count ? UInt16(b[o]) | (UInt16(b[o+1]) << 8) : 0 }
    private func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o+4 <= b.count else { return 0 }
        var v: UInt32 = 0; for i in 0..<4 { v |= UInt32(b[o+i]) << (8*i) }; return v
    }
    private func readU64(_ b: [UInt8], _ o: Int) -> UInt64 {
        guard o+8 <= b.count else { return 0 }
        var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(b[o+i]) << (8*i) }; return v
    }
}
