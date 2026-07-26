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

import Combine
import Foundation

// MARK: - Models

struct NetworkSliceEntry: Identifiable, Equatable {
    let id: String
    var label: String
    var detail: String?
    var isPrivateHost: Bool
    var countryCode: String? = nil
    var rxBytes: UInt64
    var txBytes: UInt64

    var totalBytes: UInt64 { rxBytes &+ txBytes }

    /// "DE" → "🇩🇪" via regional indicator symbols — no bundled flag assets.
    var flagEmoji: String? {
        guard let countryCode, countryCode.count == 2 else { return nil }
        var flag = ""
        for scalar in countryCode.uppercased().unicodeScalars {
            guard let indicator = UnicodeScalar(127397 + scalar.value) else { return nil }
            flag.unicodeScalars.append(indicator)
        }
        return flag
    }
}

/// One netstat socket, accumulated over the session — backs the per-host
/// connection table in the slide-in detail view.
struct NetworkSliceConnectionRow: Identifiable, Equatable {
    let id: String
    let host: String
    let localAddress: String
    let localPort: Int?
    let remotePort: Int?
    let protocolName: String
    let serviceKey: String?
    let processName: String
    var rxBytes: UInt64
    var txBytes: UInt64

    var totalBytes: UInt64 { rxBytes &+ txBytes }
}

struct NetworkSliceRatePoint: Identifiable, Equatable {
    let time: Date
    let rxRateBps: Double
    let txRateBps: Double

    var id: Date { time }
}

// MARK: - Manager

/// Drives the "Network Slice" window: while the window is open it snapshots
/// `netstat -n -b -v` every couple of seconds, diffs per-connection byte
/// counters into interval deltas, and aggregates them into remote hosts,
/// services (well-known ports), and apps. Uses the same cheap one-shot
/// netstat approach as the statistics sampler — never `nettop` on a timer.
@MainActor
final class NetworkSliceManager: ObservableObject {
    @Published private(set) var hosts: [NetworkSliceEntry] = []
    /// Hosts active in the most recent sample interval only (the "live" mode
    /// of the hosts column). rx/tx bytes are that interval's deltas.
    @Published private(set) var recentHosts: [NetworkSliceEntry] = []
    @Published private(set) var recentServices: [NetworkSliceEntry] = []
    @Published private(set) var recentPrograms: [NetworkSliceEntry] = []
    @Published private(set) var lastIntervalSeconds: Double = NetworkSliceManager.sampleInterval
    @Published private(set) var services: [NetworkSliceEntry] = []
    @Published private(set) var programs: [NetworkSliceEntry] = []
    @Published private(set) var ratePoints: [NetworkSliceRatePoint] = []
    @Published private(set) var currentTotals = RateTotals(rxRateBps: 0, txRateBps: 0)
    @Published private(set) var sessionRxBytes: UInt64 = 0
    @Published private(set) var sessionTxBytes: UInt64 = 0
    @Published private(set) var isPaused = false
    @Published private(set) var hasSample = false

    private let monitor: NetworkMonitor
    private var timer: Timer?
    private var totalsCancellable: AnyCancellable?
    private var sampleInFlight = false
    /// nil → the next snapshot only establishes the diff baseline.
    private var previousSnapshot: [String: NetworkSliceSampler.Connection]?

    private var hostTotals: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var lastHostDeltas: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var lastServiceDeltas: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var lastProgramDeltas: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var lastApplyDate: Date?
    private var privateHosts: Set<String> = []
    private var serviceTotals: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var programTotals: [String: (rx: UInt64, tx: UInt64)] = [:]

    private var connectionTotals: [String: NetworkSliceConnectionRow] = [:]

    private var hostnames: [String: String?] = [:]
    private var dnsLookupsInFlight: Set<String> = []
    private static let dnsQueue = DispatchQueue(label: "com.local.netfluss.slice.dns", qos: .utility)

    private var countryCodes: [String: String?] = [:]
    private var countryLookupsInFlight: Set<String> = []

    private static let maxVisibleEntries = 12
    private static let maxRatePoints = 240
    private static let sampleInterval: TimeInterval = 2

    init(monitor: NetworkMonitor) {
        self.monitor = monitor
    }

    var isRunning: Bool { timer != nil }

    func start() {
        stop()

        hosts = []
        recentHosts = []
        services = []
        recentServices = []
        programs = []
        recentPrograms = []
        ratePoints = []
        lastHostDeltas = [:]
        lastServiceDeltas = [:]
        lastProgramDeltas = [:]
        lastApplyDate = nil
        lastIntervalSeconds = Self.sampleInterval
        sessionRxBytes = 0
        sessionTxBytes = 0
        hasSample = false
        isPaused = false
        previousSnapshot = nil
        hostTotals = [:]
        privateHosts = []
        serviceTotals = [:]
        programTotals = [:]
        connectionTotals = [:]

        totalsCancellable = monitor.$totals
            .receive(on: DispatchQueue.main)
            .sink { [weak self] totals in
                guard let self, !self.isPaused else { return }
                self.currentTotals = totals
                self.ratePoints.append(
                    NetworkSliceRatePoint(time: Date(), rxRateBps: totals.rxRateBps, txRateBps: totals.txRateBps)
                )
                if self.ratePoints.count > Self.maxRatePoints {
                    self.ratePoints.removeFirst(self.ratePoints.count - Self.maxRatePoints)
                }
            }

        let timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleTick()
            }
        }
        timer.tolerance = 0.5
        self.timer = timer
        sampleTick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        totalsCancellable = nil
        sampleInFlight = false
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if !paused {
            // Re-baseline so traffic that flowed while paused is not counted
            // as one giant burst on the first sample after resuming.
            previousSnapshot = nil
        }
    }

    private func sampleTick() {
        guard timer != nil, !isPaused, !sampleInFlight else { return }
        sampleInFlight = true
        let previous = previousSnapshot

        Task.detached(priority: .utility) { [weak self] in
            let snapshot = NetworkSliceSampler.snapshot()
            let aggregate = previous.map { NetworkSliceSampler.aggregate(current: snapshot, previous: $0) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sampleInFlight = false
                guard self.timer != nil else { return }
                self.previousSnapshot = snapshot
                if let aggregate {
                    self.apply(aggregate)
                }
            }
        }
    }

    private func apply(_ aggregate: NetworkSliceSampler.IntervalAggregate) {
        hasSample = true
        let now = Date()
        if let lastApplyDate {
            lastIntervalSeconds = max(now.timeIntervalSince(lastApplyDate), 0.5)
        }
        lastApplyDate = now
        lastHostDeltas = aggregate.hostDeltas
        lastServiceDeltas = aggregate.serviceDeltas
        lastProgramDeltas = aggregate.programDeltas

        for (host, delta) in aggregate.hostDeltas {
            let existing = hostTotals[host] ?? (rx: 0, tx: 0)
            hostTotals[host] = (rx: existing.rx &+ delta.rx, tx: existing.tx &+ delta.tx)
        }
        privateHosts.formUnion(aggregate.privateHosts)
        for (service, delta) in aggregate.serviceDeltas {
            let existing = serviceTotals[service] ?? (rx: 0, tx: 0)
            serviceTotals[service] = (rx: existing.rx &+ delta.rx, tx: existing.tx &+ delta.tx)
        }
        for (program, delta) in aggregate.programDeltas {
            let existing = programTotals[program] ?? (rx: 0, tx: 0)
            programTotals[program] = (rx: existing.rx &+ delta.rx, tx: existing.tx &+ delta.tx)
            sessionRxBytes &+= delta.rx
            sessionTxBytes &+= delta.tx
        }
        for delta in aggregate.connectionDeltas {
            if var row = connectionTotals[delta.id] {
                row.rxBytes &+= delta.rx
                row.txBytes &+= delta.tx
                connectionTotals[delta.id] = row
            } else {
                connectionTotals[delta.id] = NetworkSliceConnectionRow(
                    id: delta.id,
                    host: delta.host,
                    localAddress: delta.localAddress,
                    localPort: delta.localPort,
                    remotePort: delta.remotePort,
                    protocolName: delta.protocolName,
                    serviceKey: delta.serviceKey,
                    processName: delta.processName,
                    rxBytes: delta.rx,
                    txBytes: delta.tx
                )
            }
        }

        rebuildEntries()
        scheduleReverseLookups()
        scheduleCountryLookups()
    }

    /// Session connection tables for the detail views, heaviest first.
    func connectionRows(forHost host: String) -> [NetworkSliceConnectionRow] {
        sortedConnectionRows { $0.host == host }
    }

    func connectionRows(forService service: String) -> [NetworkSliceConnectionRow] {
        sortedConnectionRows { $0.serviceKey == service }
    }

    func connectionRows(forProgram program: String) -> [NetworkSliceConnectionRow] {
        sortedConnectionRows { $0.processName == program }
    }

    private func sortedConnectionRows(_ isIncluded: (NetworkSliceConnectionRow) -> Bool) -> [NetworkSliceConnectionRow] {
        connectionTotals.values
            .filter(isIncluded)
            .sorted { $0.totalBytes > $1.totalBytes }
    }

    /// Resolved reverse-DNS name for a host, if a lookup has completed.
    func resolvedHostname(for host: String) -> String? {
        hostnames[host] ?? nil
    }

    private func rebuildEntries() {
        hosts = topEntries(from: hostTotals, build: hostEntry)
        recentHosts = topEntries(from: lastHostDeltas, build: hostEntry)
        services = topEntries(from: serviceTotals, build: serviceEntry)
        recentServices = topEntries(from: lastServiceDeltas, build: serviceEntry)
        programs = topEntries(from: programTotals, build: programEntry)
        recentPrograms = topEntries(from: lastProgramDeltas, build: programEntry)
    }

    private func serviceEntry(_ service: String, rx: UInt64, tx: UInt64) -> NetworkSliceEntry {
        NetworkSliceEntry(
            id: service,
            label: NetworkSliceSampler.serviceDisplayName(for: service),
            detail: nil,
            isPrivateHost: false,
            rxBytes: rx,
            txBytes: tx
        )
    }

    private func programEntry(_ program: String, rx: UInt64, tx: UInt64) -> NetworkSliceEntry {
        NetworkSliceEntry(
            id: program,
            label: program,
            detail: nil,
            isPrivateHost: false,
            rxBytes: rx,
            txBytes: tx
        )
    }

    private func hostEntry(_ host: String, rx: UInt64, tx: UInt64) -> NetworkSliceEntry {
        let resolved = hostnames[host] ?? nil
        return NetworkSliceEntry(
            id: host,
            label: resolved ?? host,
            detail: resolved != nil ? host : nil,
            isPrivateHost: privateHosts.contains(host),
            countryCode: countryCodes[host] ?? nil,
            rxBytes: rx,
            txBytes: tx
        )
    }

    private func topEntries(
        from totals: [String: (rx: UInt64, tx: UInt64)],
        build: (String, UInt64, UInt64) -> NetworkSliceEntry
    ) -> [NetworkSliceEntry] {
        totals
            .sorted { ($0.value.rx &+ $0.value.tx) > ($1.value.rx &+ $1.value.tx) }
            .prefix(Self.maxVisibleEntries)
            .map { build($0.key, $0.value.rx, $0.value.tx) }
    }

    // MARK: - Country lookup

    /// Resolves the country of the top public hosts via api.country.is (HTTPS,
    /// keyless), one request per IP per session, cached including failures.
    private func scheduleCountryLookups() {
        for entry in (hosts + recentHosts) where !entry.isPrivateHost {
            let host = entry.id
            guard countryCodes.index(forKey: host) == nil, !countryLookupsInFlight.contains(host) else { continue }
            countryLookupsInFlight.insert(host)
            Task { [weak self] in
                let code = await NetworkSliceSampler.countryCode(for: host)
                await MainActor.run {
                    guard let self else { return }
                    self.countryLookupsInFlight.remove(host)
                    self.countryCodes[host] = code
                    if code != nil {
                        self.rebuildEntries()
                    }
                }
            }
        }
    }

    // MARK: - Reverse DNS

    private func scheduleReverseLookups() {
        for entry in (hosts + recentHosts) {
            let host = entry.id
            guard hostnames.index(forKey: host) == nil, !dnsLookupsInFlight.contains(host) else { continue }
            dnsLookupsInFlight.insert(host)
            Self.dnsQueue.async { [weak self] in
                let resolved = NetworkSliceSampler.reverseLookup(host)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.dnsLookupsInFlight.remove(host)
                    self.hostnames[host] = resolved
                    if resolved != nil {
                        self.rebuildEntries()
                    }
                }
            }
        }
    }
}

// MARK: - Sampler (off-main)

/// Parses `netstat -n -b -v` keeping the endpoint addresses that the
/// Top-Apps sampler discards, so traffic can be attributed to remote hosts
/// and well-known service ports as well as processes.
enum NetworkSliceSampler {

    struct Connection {
        let id: String
        let processName: String
        let remoteHost: String?
        let localHost: String?
        let localPort: Int?
        let remotePort: Int?
        let protocolName: String
        let isNetworkSource: Bool
        let rxBytes: UInt64
        let txBytes: UInt64
    }

    struct ConnectionDelta {
        let id: String
        let host: String
        let localAddress: String
        let localPort: Int?
        let remotePort: Int?
        let protocolName: String
        let serviceKey: String?
        let processName: String
        let rx: UInt64
        let tx: UInt64
    }

    struct IntervalAggregate {
        var hostDeltas: [String: (rx: UInt64, tx: UInt64)] = [:]
        var privateHosts: Set<String> = []
        var serviceDeltas: [String: (rx: UInt64, tx: UInt64)] = [:]
        var programDeltas: [String: (rx: UInt64, tx: UInt64)] = [:]
        var connectionDeltas: [ConnectionDelta] = []
    }

    static func snapshot() -> [String: Connection] {
        ProcessNetworkSampler.clearNameCacheIfNeeded()
        let output = runNetstat()
        var connections: [String: Connection] = [:]

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 8 else { continue }
            let proto = String(parts[0])
            let isTCP = proto.hasPrefix("tcp")
            let isUDP = proto.hasPrefix("udp")
            let isNetworkSource = proto == "kctl" && parts.last == "com.apple.netsrc"
            guard isTCP || isUDP || isNetworkSource else { continue }

            // Same column layout as ProcessNetworkSampler.sampleConnectionsFromNetstat:
            // TCP:  proto recv-q send-q local foreign STATE rxbytes txbytes ...
            // UDP:  proto recv-q send-q local foreign rxbytes txbytes ...
            // KCTL: proto recv-q send-q rxbytes txbytes rhiwat shiwat process:pid ...
            let rxIndex = isTCP ? 6 : (isUDP ? 5 : 3)
            let txIndex = rxIndex + 1
            guard txIndex < parts.count,
                  let rx = UInt64(parts[rxIndex]),
                  let tx = UInt64(parts[txIndex]),
                  rx > 0 || tx > 0 else { continue }

            var pid: pid_t? = nil
            if let pidToken = parts.first(where: { token in
                token.contains(":") &&
                token.split(separator: ":", omittingEmptySubsequences: true)
                     .last.flatMap({ Int32($0) }) != nil
            }) {
                pid = pidToken.split(separator: ":").last.flatMap({ Int32($0) })
            } else {
                let pidIdx = rxIndex + 4
                if pidIdx < parts.count { pid = Int32(parts[pidIdx]) }
            }
            guard let pid, pid > 0 else { continue }
            let name = ProcessNetworkSampler.cachedProcessName(for: pid)

            var remoteHost: String? = nil
            var localHost: String? = nil
            var localPort: Int? = nil
            var remotePort: Int? = nil
            let connectionID: String

            if isNetworkSource {
                guard parts.count >= 19 else { continue }
                connectionID = [proto, String(pid), String(parts[16]), String(parts[17]), String(parts[18])]
                    .joined(separator: "|")
            } else {
                let local = endpoint(parts[3])
                let remote = endpoint(parts[4])
                // Skip loopback traffic entirely — it never touches the network.
                if isLoopback(local.host) || isLoopback(remote.host) { continue }
                remoteHost = remote.host
                localHost = local.host
                localPort = local.port
                remotePort = remote.port
                connectionID = [proto, String(parts[3]), String(parts[4]), String(pid)]
                    .joined(separator: "|")
            }

            connections[connectionID] = Connection(
                id: connectionID,
                processName: name,
                remoteHost: remoteHost,
                localHost: localHost,
                localPort: localPort,
                remotePort: remotePort,
                protocolName: isTCP ? "TCP" : (isUDP ? "UDP" : "kctl"),
                isNetworkSource: isNetworkSource,
                rxBytes: rx,
                txBytes: tx
            )
        }
        return connections
    }

    /// Diff two snapshots into per-host / per-service / per-app interval deltas.
    /// Connections absent from `previous` count their full bytes (they opened
    /// within the interval) — same semantics as the statistics sampler.
    static func aggregate(
        current: [String: Connection],
        previous: [String: Connection]
    ) -> IntervalAggregate {
        var result = IntervalAggregate()
        // Per-app socket vs netsrc buckets; the bigger one wins per app, like
        // ProcessNetworkSampler.appDeltas, so WebKit traffic (netsrc-only) is
        // not lost and normal apps are not double-counted.
        var programSocket: [String: (rx: UInt64, tx: UInt64)] = [:]
        var programNetsrc: [String: (rx: UInt64, tx: UInt64)] = [:]

        for connection in current.values {
            let rxDelta: UInt64
            let txDelta: UInt64
            if let prior = previous[connection.id] {
                rxDelta = connection.rxBytes >= prior.rxBytes ? connection.rxBytes - prior.rxBytes : connection.rxBytes
                txDelta = connection.txBytes >= prior.txBytes ? connection.txBytes - prior.txBytes : connection.txBytes
            } else {
                rxDelta = connection.rxBytes
                txDelta = connection.txBytes
            }
            guard rxDelta > 0 || txDelta > 0 else { continue }

            if connection.isNetworkSource {
                let existing = programNetsrc[connection.processName] ?? (rx: 0, tx: 0)
                programNetsrc[connection.processName] = (rx: existing.rx &+ rxDelta, tx: existing.tx &+ txDelta)
                continue
            }

            let existing = programSocket[connection.processName] ?? (rx: 0, tx: 0)
            programSocket[connection.processName] = (rx: existing.rx &+ rxDelta, tx: existing.tx &+ txDelta)

            if let host = connection.remoteHost {
                let hostExisting = result.hostDeltas[host] ?? (rx: 0, tx: 0)
                result.hostDeltas[host] = (rx: hostExisting.rx &+ rxDelta, tx: hostExisting.tx &+ txDelta)
                if isPrivateHost(host) {
                    result.privateHosts.insert(host)
                }
            }

            // Unconnected UDP sockets (mDNS, SSDP, Plex discovery, …) have no
            // remote endpoint in the socket table — record them under "*" so
            // service/app detail tables still list them. Hosts stay real-only.
            result.connectionDeltas.append(ConnectionDelta(
                id: connection.id,
                host: connection.remoteHost ?? "*",
                localAddress: connection.localHost ?? "*",
                localPort: connection.localPort,
                remotePort: connection.remotePort,
                protocolName: connection.protocolName,
                serviceKey: serviceKey(localPort: connection.localPort, remotePort: connection.remotePort),
                processName: connection.processName,
                rx: rxDelta,
                tx: txDelta
            ))

            if let service = serviceKey(localPort: connection.localPort, remotePort: connection.remotePort) {
                let serviceExisting = result.serviceDeltas[service] ?? (rx: 0, tx: 0)
                result.serviceDeltas[service] = (rx: serviceExisting.rx &+ rxDelta, tx: serviceExisting.tx &+ txDelta)
            }
        }

        for name in Set(programSocket.keys).union(programNetsrc.keys) {
            let socket = programSocket[name] ?? (rx: 0, tx: 0)
            let netsrc = programNetsrc[name] ?? (rx: 0, tx: 0)
            result.programDeltas[name] = (netsrc.rx &+ netsrc.tx) > (socket.rx &+ socket.tx) ? netsrc : socket
        }

        return result
    }

    // MARK: - Endpoint helpers

    /// netstat prints endpoints as `address.port` (port after the LAST dot,
    /// which also works for IPv6). `*` means unbound on either side.
    private static func endpoint(_ token: Substring) -> (host: String?, port: Int?) {
        guard let lastDot = token.lastIndex(of: ".") else { return (nil, nil) }
        var host = String(token[..<lastDot])
        let port = Int(token[token.index(after: lastDot)...])
        if host == "*" || host.isEmpty { return (nil, port) }
        if let percent = host.firstIndex(of: "%") {
            host = String(host[..<percent])
        }
        return (host, port)
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host else { return false }
        return host.hasPrefix("127.") || host == "::1"
    }

    static func isPrivateHost(_ host: String) -> Bool {
        if host.contains(":") {
            let lower = host.lowercased()
            return lower.hasPrefix("fe80") || lower.hasPrefix("fd") || lower.hasPrefix("fc") || lower.hasPrefix("ff")
        }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") { return true }
        if host.hasPrefix("172.") {
            let second = host.dropFirst(4).prefix(while: { $0 != "." })
            if let value = Int(second), (16...31).contains(value) { return true }
        }
        if host.hasPrefix("224.") || host.hasPrefix("239.") || host.hasSuffix(".255") { return true }
        return false
    }

    // MARK: - Services

    /// Stable aggregation key: a well-known service name, or "#port" for
    /// unrecognized ports (localized to "Port N" at display time).
    private static func serviceKey(localPort: Int?, remotePort: Int?) -> String? {
        if let remotePort, let name = wellKnownPorts[remotePort] { return name }
        if let localPort, let name = wellKnownPorts[localPort] { return name }
        let candidates = [remotePort, localPort].compactMap { $0 }.filter { $0 > 0 }
        guard let port = candidates.min() else { return nil }
        // Ephemeral-to-ephemeral flows (games, P2P, WebRTC) would otherwise
        // flood the column with one-off "Port N" rows — bucket them together.
        if port >= 32768 { return "#other" }
        return "#\(port)"
    }

    static func serviceDisplayName(for key: String) -> String {
        if key == "#other" { return L10n.text("Other") }
        if key.hasPrefix("#"), let port = Int(key.dropFirst()) {
            return L10n.format("Port %d", port)
        }
        return key
    }

    private static let wellKnownPorts: [Int: String] = [
        20: "ftp-data", 21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp",
        53: "domain", 67: "dhcp", 68: "dhcp", 80: "http", 88: "kerberos",
        110: "pop3", 123: "ntp", 137: "netbios-ns", 138: "netbios-dgm", 139: "netbios-ssn",
        143: "imap", 161: "snmp", 194: "irc", 389: "ldap", 443: "https",
        445: "smb", 465: "smtps", 500: "isakmp", 514: "syslog", 546: "dhcpv6", 547: "dhcpv6",
        548: "afp", 587: "submission", 636: "ldaps", 853: "dns-over-tls", 873: "rsync",
        993: "imaps", 995: "pop3s", 1194: "openvpn", 1701: "l2tp", 1723: "pptp",
        1900: "ssdp", 3283: "net-assistant", 3389: "rdp", 3478: "stun", 3689: "daap",
        4500: "ipsec-nat-t", 5060: "sip", 5222: "xmpp-client", 5223: "apns",
        5228: "google-play", 5353: "zeroconf", 5900: "vnc", 7000: "airplay",
        8080: "http-alt", 8443: "https-alt", 51820: "wireguard", 62078: "iphone-sync"
    ]

    // MARK: - Country lookup

    /// ISO country code for a public IP via https://api.country.is/<ip>.
    /// Keyless and rate-limit friendly at our volume (≤12 hosts, once per
    /// session each). Returns nil on any failure — cached by the caller so a
    /// dead endpoint costs one request per host, not one per sample.
    static func countryCode(for ip: String) async -> String? {
        guard let url = URL(string: "https://api.country.is/\(ip)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct CountryResponse: Decodable { let country: String? }
        guard let code = (try? JSONDecoder().decode(CountryResponse.self, from: data))?.country,
              code.count == 2 else { return nil }
        return code.uppercased()
    }

    // MARK: - Reverse DNS

    /// Blocking reverse lookup — must run on a background queue. Returns nil
    /// when the address has no PTR record (NI_NAMEREQD).
    static func reverseLookup(_ ip: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var result: Int32 = -1

        if ip.contains(":") {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            guard inet_pton(AF_INET6, ip, &addr.sin6_addr) == 1 else { return nil }
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in6>.size),
                                &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                                &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
                }
            }
        }

        guard result == 0 else { return nil }
        var name = String(cString: buffer)
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name != ip else { return nil }
        return simplifiedDomain(name)
    }

    /// "ber01s21-in-f14.1e100.net" → "1e100.net"; keeps ".local" names intact.
    static func simplifiedDomain(_ hostname: String) -> String {
        let labels = hostname.split(separator: ".")
        guard labels.count > 2, labels.last != "local" else { return hostname }
        let secondLevelDomains: Set<Substring> = ["co", "com", "net", "org", "ac", "gov", "edu"]
        let keep = (labels.count > 3 && secondLevelDomains.contains(labels[labels.count - 2])) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    private static func runNetstat() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-n", "-b", "-v"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        // Read before waitUntilExit to avoid pipe-buffer deadlock (~185 KB output)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
