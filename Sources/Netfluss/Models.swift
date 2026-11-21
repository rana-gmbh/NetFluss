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

enum AdapterType: String, Equatable, Sendable {
    case wifi
    case ethernet
    case other
}

enum AdapterClassifier {
    private static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap"]

    /// Interfaces that never carry real internet uplink traffic and must NEVER be
    /// counted in usage totals — loopback, AirDrop/AWDL, and other link-local /
    /// virtual devices. Counting them is a bug: a localhost SOCKS/HTTP proxy
    /// double-counts via `lo0`, and AirDrop is local peer-to-peer, not internet
    /// (issue #54).
    private static let nonInternetPrefixes = ["lo", "awdl", "llw", "gif", "stf", "anpi"]

    static func isTunnelInterface(named name: String) -> Bool {
        let normalizedName = name.lowercased()
        return tunnelPrefixes.contains { normalizedName.hasPrefix($0) }
    }

    /// Whether an interface never counts toward usage totals, regardless of the
    /// exclude-tunnels toggle.
    static func isNonInternetInterface(named name: String) -> Bool {
        let normalizedName = name.lowercased()
        return nonInternetPrefixes.contains { normalizedName.hasPrefix($0) }
    }

    /// Single source of truth for whether an interface's bytes count toward usage
    /// totals. Used by the live header totals AND the Statistics/Data Usage totals
    /// so they always agree.
    static func countsTowardTotals(named name: String, excludeTunnels: Bool) -> Bool {
        if isNonInternetInterface(named: name) { return false }
        if excludeTunnels, isTunnelInterface(named: name) { return false }
        return true
    }
}

struct AdapterStatus: Identifiable, Equatable, Sendable {
    let id: String          // BSD name (e.g. "en0")
    let displayName: String
    let type: AdapterType
    let isTunnelInterface: Bool
    let isUp: Bool
    let linkSpeedBps: UInt64?
    let wifiMode: String?
    let wifiTxRateMbps: Double?
    let wifiSSID: String?
    let wifiDetail: WifiDetail?
    let rxBytes: UInt64
    let txBytes: UInt64
    let rxRateBps: Double
    let txRateBps: Double

    /// This adapter with its live counters cleared, for views that show what an
    /// adapter is rather than what it's doing.
    var withoutTraffic: AdapterStatus {
        AdapterStatus(
            id: id,
            displayName: displayName,
            type: type,
            isTunnelInterface: isTunnelInterface,
            isUp: isUp,
            linkSpeedBps: linkSpeedBps,
            wifiMode: wifiMode,
            wifiTxRateMbps: nil,
            wifiSSID: wifiSSID,
            wifiDetail: wifiDetail,
            rxBytes: 0,
            txBytes: 0,
            rxRateBps: 0,
            txRateBps: 0
        )
    }

    func with(rxRateBps newRxRate: Double? = nil, rxBytes newRxBytes: UInt64? = nil) -> AdapterStatus {
        AdapterStatus(
            id: id,
            displayName: displayName,
            type: type,
            isTunnelInterface: isTunnelInterface,
            isUp: isUp,
            linkSpeedBps: linkSpeedBps,
            wifiMode: wifiMode,
            wifiTxRateMbps: wifiTxRateMbps,
            wifiSSID: wifiSSID,
            wifiDetail: wifiDetail,
            rxBytes: newRxBytes ?? rxBytes,
            txBytes: txBytes,
            rxRateBps: newRxRate ?? rxRateBps,
            txRateBps: txRateBps
        )
    }
}

struct RateTotals: Equatable, Sendable {
    let rxRateBps: Double
    let txRateBps: Double
}

enum AdapterTotalsFilter {
    static func visibleAdapters(
        from adapters: [AdapterStatus],
        showOtherAdapters: Bool,
        showInactive: Bool,
        graceEnabled: Bool,
        hidden: Set<String>,
        graceDeadlines: [String: Date]
    ) -> [AdapterStatus] {
        adapters.filter {
            isVisible(
                $0,
                showOtherAdapters: showOtherAdapters,
                showInactive: showInactive,
                graceEnabled: graceEnabled,
                hidden: hidden,
                graceDeadlines: graceDeadlines
            )
        }
    }

    static func totals(
        from adapters: [AdapterStatus],
        onlyVisible: Bool,
        excludeTunnelAdapters: Bool,
        showOtherAdapters: Bool,
        showInactive: Bool,
        graceEnabled: Bool,
        hidden: Set<String>,
        graceDeadlines: [String: Date]
    ) -> RateTotals {
        var rx: Double = 0
        var tx: Double = 0

        for adapter in adapters {
            if onlyVisible,
               !isVisible(
                adapter,
                showOtherAdapters: showOtherAdapters,
                showInactive: showInactive,
                graceEnabled: graceEnabled,
                hidden: hidden,
                graceDeadlines: graceDeadlines
               ) {
                continue
            }
            guard AdapterClassifier.countsTowardTotals(named: adapter.id, excludeTunnels: excludeTunnelAdapters) else {
                continue
            }
            rx += adapter.rxRateBps
            tx += adapter.txRateBps
        }

        return RateTotals(rxRateBps: rx, txRateBps: tx)
    }

    private static func isVisible(
        _ adapter: AdapterStatus,
        showOtherAdapters: Bool,
        showInactive: Bool,
        graceEnabled: Bool,
        hidden: Set<String>,
        graceDeadlines: [String: Date]
    ) -> Bool {
        if !showOtherAdapters, adapter.type == .other { return false }
        if hidden.contains(adapter.id) { return false }

        let zeroBandwidth = adapter.rxRateBps == 0 && adapter.txRateBps == 0
        if graceEnabled, zeroBandwidth {
            return graceDeadlines[adapter.id] != nil
        }
        if !showInactive, zeroBandwidth, !adapter.isUp {
            return false
        }
        return true
    }
}

struct AppTraffic: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let rxRateBps: Double
    let txRateBps: Double
}

struct WifiDetail: Equatable, Sendable {
    let phyMode: String?
    let security: String?
    let channelNumber: Int?
    let channelWidth: String?
    let rssi: Int?
    let noise: Int?
    let bssid: String?
}

struct InterfaceSample: Equatable, Sendable {
    let name: String
    let flags: UInt32
    let rxBytes: UInt64
    let txBytes: UInt64
    let baudrate: UInt64
}

struct WifiNetwork: Identifiable, Equatable, Sendable {
    let id: String           // Stable per-network key (BSSID if present, else SSID)
    let ssid: String
    let bssid: String?
    let rssi: Int?           // nil for pinned-but-out-of-range entries
    let isSecured: Bool
    let security: String?    // Localised label ("WPA2 Personal", "Open", ...)
    let channelNumber: Int?
    let channelWidth: String?
    let band: String?        // "2.4 GHz" / "5 GHz" / "6 GHz"
    let isCurrent: Bool
    let isSaved: Bool        // Known to macOS via stored network profiles
    let isPinned: Bool       // User-pinned in NetFluss preferences
    let isAvailable: Bool    // false when synthesised for an out-of-range pinned SSID
}

/// The customisable sections of the popover, in their default top-to-bottom
/// order. Persisted as `popoverSectionOrder` (an array of rawValues) and
/// `popoverSection.<id>.visible` style toggles are aliased to the existing
/// canonical visibility keys (see PopoverSection.visibilityKey).
enum PopoverSection: String, CaseIterable, Identifiable, Sendable {
    case totals
    case usage
    case adapters
    case connection
    case dns
    case router
    case wifi
    case vpn
    case topApps
    case timer

    var id: String { rawValue }

    static let defaultOrder: [PopoverSection] = [
        .totals, .adapters, .connection, .dns, .router, .wifi, .vpn, .topApps, .usage, .timer
    ]

    var displayName: String {
        switch self {
        case .totals: return "Download / Upload"
        case .usage: return "Data Usage"
        case .adapters: return "Network adapters"
        case .connection: return "Network flow"
        case .dns: return "DNS"
        case .router: return "Router"
        case .wifi: return "Wi-Fi Networks"
        case .vpn: return "VPN"
        case .topApps: return "Top Apps"
        case .timer: return "Traffic Timer"
        }
    }

    var systemImage: String {
        switch self {
        case .totals: return "arrow.up.arrow.down"
        case .usage: return "chart.bar.doc.horizontal"
        case .adapters: return "network"
        case .connection: return "globe"
        case .dns: return "server.rack"
        case .router: return "wifi.router"
        case .wifi: return "wifi"
        case .vpn: return "lock.shield"
        case .topApps: return "list.number"
        case .timer: return "stopwatch"
        }
    }

    static func resolvedOrder(from raw: [String]?) -> [PopoverSection] {
        guard let raw, !raw.isEmpty else { return defaultOrder }
        var seen = Set<PopoverSection>()
        var ordered: [PopoverSection] = []
        for token in raw {
            guard let section = PopoverSection(rawValue: token) else { continue }
            if seen.insert(section).inserted { ordered.append(section) }
        }
        // Append any sections that aren't in the stored order (new defaults).
        for section in defaultOrder where !seen.contains(section) {
            ordered.append(section)
        }
        return ordered
    }
}

/// How a preset talks to its resolver.
///
/// Encrypted transports go through macOS's own encrypted-DNS configuration
/// (`NEDNSSettingsManager`), never through a local proxy: the system resolver
/// speaks DoH/DoT itself, so nothing of NetFluss has to keep running for it.
/// DNS-over-QUIC is deliberately absent — macOS has no native support for it.
enum DNSTransport: Codable, Equatable, Hashable, Sendable {
    case https(url: String)
    case tls(serverName: String)

    /// Short protocol tag for badges and labels. Not localised: DoH and DoT are
    /// the names people search for.
    var shortName: String {
        switch self {
        case .https: return "DoH"
        case .tls: return "DoT"
        }
    }

    /// The URL or TLS server name, for the secondary line under a preset.
    var endpoint: String {
        switch self {
        case .https(let url): return url
        case .tls(let serverName): return serverName
        }
    }
}

/// What a preset points the system at, used to tell whether it is already in
/// effect. A DoH preset and a plain preset with the same bootstrap IPs are two
/// different resolvers, so the transport is part of the identity.
enum DNSResolverTarget: Equatable, Sendable {
    case plain([String])
    case encrypted(DNSTransport, servers: [String])
}

struct DNSPreset: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    /// Plain presets: the resolvers, empty = system default (DHCP).
    /// Encrypted presets: bootstrap addresses for the DoH host / DoT server.
    let servers: [String]
    let isBuiltIn: Bool
    /// nil = plain DNS on port 53. Optional so presets saved by older versions
    /// decode unchanged.
    let transport: DNSTransport?

    init(id: String, name: String, servers: [String], isBuiltIn: Bool, transport: DNSTransport? = nil) {
        self.id = id
        self.name = name
        self.servers = servers
        self.isBuiltIn = isBuiltIn
        self.transport = transport
    }

    var isEncrypted: Bool { transport != nil }

    var target: DNSResolverTarget {
        if let transport { return .encrypted(transport, servers: servers) }
        return .plain(servers)
    }

    /// A built-in's own name in the app language. Only System Default is
    /// translated, the others are brand names. It has a key of its own because the
    /// language picker's "System Default" means the system language, which German
    /// calls "Systemsprache" (#71).
    var localizedName: String {
        isBuiltIn && id == "system" ? L10n.text("System Default DNS") : name
    }

    /// Same resolver, different label.
    func renamed(_ newName: String) -> DNSPreset {
        DNSPreset(id: id, name: newName, servers: servers, isBuiltIn: isBuiltIn, transport: transport)
    }

    static let builtIn: [DNSPreset] = plainBuiltIn + encryptedBuiltIn

    static let plainBuiltIn: [DNSPreset] = [
        DNSPreset(id: "system",    name: "System Default", servers: [],                              isBuiltIn: true),
        DNSPreset(id: "cloudflare",name: "Cloudflare",     servers: ["1.1.1.1", "1.0.0.1"],          isBuiltIn: true),
        DNSPreset(id: "google",    name: "Google",         servers: ["8.8.8.8", "8.8.4.4"],          isBuiltIn: true),
        DNSPreset(id: "quad9",     name: "Quad9",          servers: ["9.9.9.9", "149.112.112.112"],  isBuiltIn: true),
        DNSPreset(id: "opendns",   name: "OpenDNS",        servers: ["208.67.222.222", "208.67.220.220"], isBuiltIn: true),
    ]

    /// Encrypted built-ins. They start hidden in the popover (see
    /// `hideNewEncryptedBuiltIns`) so an update doesn't more than double the
    /// switcher; Preferences › DNS turns them on. OpenDNS has no DoT service.
    static let encryptedBuiltIn: [DNSPreset] = {
        let cloudflare = ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]
        let google = ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"]
        let quad9 = ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]
        let openDNS = ["208.67.222.222", "208.67.220.220", "2620:119:35::35", "2620:119:53::53"]
        let mullvad = ["194.242.2.2", "2a07:e340::2"]
        let adGuard = ["94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"]
        return [
            DNSPreset(id: "cloudflare-doh", name: "Cloudflare (DoH)", servers: cloudflare, isBuiltIn: true,
                      transport: .https(url: "https://cloudflare-dns.com/dns-query")),
            DNSPreset(id: "cloudflare-dot", name: "Cloudflare (DoT)", servers: cloudflare, isBuiltIn: true,
                      transport: .tls(serverName: "one.one.one.one")),
            DNSPreset(id: "google-doh", name: "Google (DoH)", servers: google, isBuiltIn: true,
                      transport: .https(url: "https://dns.google/dns-query")),
            DNSPreset(id: "google-dot", name: "Google (DoT)", servers: google, isBuiltIn: true,
                      transport: .tls(serverName: "dns.google")),
            DNSPreset(id: "quad9-doh", name: "Quad9 (DoH)", servers: quad9, isBuiltIn: true,
                      transport: .https(url: "https://dns.quad9.net/dns-query")),
            DNSPreset(id: "quad9-dot", name: "Quad9 (DoT)", servers: quad9, isBuiltIn: true,
                      transport: .tls(serverName: "dns.quad9.net")),
            DNSPreset(id: "opendns-doh", name: "OpenDNS (DoH)", servers: openDNS, isBuiltIn: true,
                      transport: .https(url: "https://doh.opendns.com/dns-query")),
            DNSPreset(id: "mullvad-doh", name: "Mullvad (DoH)", servers: mullvad, isBuiltIn: true,
                      transport: .https(url: "https://dns.mullvad.net/dns-query")),
            DNSPreset(id: "mullvad-dot", name: "Mullvad (DoT)", servers: mullvad, isBuiltIn: true,
                      transport: .tls(serverName: "dns.mullvad.net")),
            DNSPreset(id: "adguard-doh", name: "AdGuard (DoH)", servers: adGuard, isBuiltIn: true,
                      transport: .https(url: "https://dns.adguard-dns.com/dns-query")),
            DNSPreset(id: "adguard-dot", name: "AdGuard (DoT)", servers: adGuard, isBuiltIn: true,
                      transport: .tls(serverName: "dns.adguard-dns.com")),
        ]
    }()

    /// Adds encrypted built-ins this install hasn't seen yet to the hidden set,
    /// once each, so a later "show" in Preferences sticks. Fresh installs get
    /// the same treatment: the popover starts with the plain five either way.
    static func hideNewEncryptedBuiltIns(defaults: UserDefaults = .standard) {
        let seenKey = "dnsSeenEncryptedBuiltIns"
        let seen = Set(defaults.stringArray(forKey: seenKey) ?? [])
        let new = encryptedBuiltIn.map(\.id).filter { !seen.contains($0) }
        guard !new.isEmpty else { return }
        var hidden = defaults.stringArray(forKey: "hiddenDNSPresets") ?? []
        for id in new where !hidden.contains(id) { hidden.append(id) }
        defaults.set(hidden, forKey: "hiddenDNSPresets")
        defaults.set(Array(seen) + new, forKey: seenKey)
    }
}
