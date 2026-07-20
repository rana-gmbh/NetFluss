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

    var id: String { rawValue }

    static let defaultOrder: [PopoverSection] = [
        .totals, .adapters, .connection, .dns, .router, .wifi, .vpn, .topApps, .usage
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

struct DNSPreset: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let servers: [String]  // empty = system default (DHCP)
    let isBuiltIn: Bool

    static let builtIn: [DNSPreset] = [
        DNSPreset(id: "system",    name: "System Default", servers: [],                              isBuiltIn: true),
        DNSPreset(id: "cloudflare",name: "Cloudflare",     servers: ["1.1.1.1", "1.0.0.1"],          isBuiltIn: true),
        DNSPreset(id: "google",    name: "Google",         servers: ["8.8.8.8", "8.8.4.4"],          isBuiltIn: true),
        DNSPreset(id: "quad9",     name: "Quad9",          servers: ["9.9.9.9", "149.112.112.112"],  isBuiltIn: true),
        DNSPreset(id: "opendns",   name: "OpenDNS",        servers: ["208.67.222.222", "208.67.220.220"], isBuiltIn: true),
    ]
}
