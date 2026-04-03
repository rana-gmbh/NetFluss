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

import SwiftUI
import AppKit

struct MenuBarView: View {
    let preferredWidth: CGFloat
    let screenVisibleFrame: CGRect

    @EnvironmentObject private var monitor: NetworkMonitor
    @AppStorage("showInactive") private var showInactive: Bool = false
    @AppStorage("adapterGracePeriodEnabled") private var adapterGracePeriodEnabled: Bool = false
    @AppStorage("showOtherAdapters") private var showOtherAdapters: Bool = false
    @AppStorage("useBits") private var useBits: Bool = false
    @AppStorage("showTopApps") private var showTopApps: Bool = false
    @AppStorage("uploadColor") private var uploadColorName: String = "green"
    @AppStorage("uploadColorHex") private var uploadColorHex: String = ""
    @AppStorage("downloadColor") private var downloadColorName: String = "blue"
    @AppStorage("downloadColorHex") private var downloadColorHex: String = ""
    @AppStorage("totalsOnlyVisibleAdapters") private var totalsOnlyVisibleAdapters: Bool = false
    @AppStorage("excludeTunnelAdaptersFromTotals") private var excludeTunnelAdaptersFromTotals: Bool = false
    @AppStorage("connectionStatusMode") private var connectionStatusMode: String = "list"
    @AppStorage("showDNSSwitcher") private var showDNSSwitcher: Bool = false
    @AppStorage("fritzBoxEnabled") private var fritzBoxEnabled: Bool = false
    @AppStorage("unifiEnabled") private var unifiEnabled: Bool = false
    @AppStorage("openWRTEnabled") private var openWRTEnabled: Bool = false

    private static let cardSpacing: CGFloat = 6   // VStack spacing between cards
    @State private var contentHeight: CGFloat = 0
    // Cached JSON decode — updated via notification, not every render
    @State private var cachedCustomNames: [String: String] = {
        (try? JSONDecoder().decode([String: String].self,
            from: UserDefaults.standard.data(forKey: "adapterCustomNames") ?? Data())) ?? [:]
    }()

    init(
        preferredWidth: CGFloat = 340,
        screenVisibleFrame: CGRect = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    ) {
        self.preferredWidth = preferredWidth
        self.screenVisibleFrame = screenVisibleFrame
    }

    var body: some View {
        let theme = AppTheme.system
        let hiddenAdapters = Set(UserDefaults.standard.stringArray(forKey: "hiddenAdapters") ?? [])
        let adapters = filteredAdapters(hidden: hiddenAdapters)
        let headerTotals = AdapterTotalsFilter.totals(
            from: monitor.adapters,
            onlyVisible: totalsOnlyVisibleAdapters,
            excludeTunnelAdapters: excludeTunnelAdaptersFromTotals,
            showOtherAdapters: showOtherAdapters,
            showInactive: showInactive,
            graceEnabled: adapterGracePeriodEnabled,
            hidden: hiddenAdapters,
            graceDeadlines: monitor.adapterGraceDeadlines
        )
        let customNames = cachedCustomNames

        let screenMax = max(screenVisibleFrame.height - 30, 240)
        let savedHeight = UserDefaults.standard.double(forKey: "popoverHeight")
        let heightLimit = savedHeight > 0 ? min(savedHeight, screenMax) : screenMax

        let scrollHeight = min(contentHeight, heightLimit)

        VStack(spacing: 0) {
            popoverContent(adapters: adapters, customNames: customNames, headerTotals: headerTotals)
                .frame(height: contentHeight > 0 ? scrollHeight : nil)

            PopoverResizeHandle()
        }
        .background(theme.backgroundColor ?? .clear)
        .frame(width: preferredWidth)
        .environment(\.appTheme, theme)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            cachedCustomNames = (try? JSONDecoder().decode([String: String].self,
                from: UserDefaults.standard.data(forKey: "adapterCustomNames") ?? Data())) ?? [:]
        }
    }

    private var downloadAccent: Color {
        resolvedAccentColor(selection: downloadColorName, customHex: downloadColorHex, fallback: AppTheme.system.downloadColor)
    }

    private var uploadAccent: Color {
        resolvedAccentColor(selection: uploadColorName, customHex: uploadColorHex, fallback: AppTheme.system.uploadColor)
    }

    private var cardSpacing: CGFloat { Self.cardSpacing }

    @ViewBuilder
    private func popoverContent(adapters: [AdapterStatus], customNames: [String: String], headerTotals: RateTotals) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                TotalRatesHeader(totals: headerTotals, useBits: useBits)

                Divider()

                if adapters.isEmpty {
                    Text("No active adapters")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                } else {
                    VStack(spacing: cardSpacing) {
                        ForEach(adapters) { adapter in
                            AdapterCard(
                                adapter: adapter,
                                useBits: useBits,
                                customName: customNames[adapter.id],
                                isReconnecting: monitor.reconnectingAdapters.contains(adapter.id),
                                onReconnect: adapter.type != .other ? { monitor.reconnect(adapter: adapter) } : nil
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }

                Divider()
                if connectionStatusMode == "flow" {
                    ConnectionStatusSection(
                        externalIP: monitor.externalIP,
                        internalIP: monitor.internalIP,
                        gatewayIP: monitor.gatewayIP,
                        adapters: monitor.adapters,
                        countryCode: monitor.externalIPCountryCode
                    )
                } else {
                    IPAddressSection(
                        externalIP: monitor.externalIP,
                        internalIP: monitor.internalIP,
                        gatewayIP: monitor.gatewayIP
                    )
                }

                if fritzBoxEnabled {
                    Divider()
                    FritzBoxSection(useBits: useBits)
                }

                if unifiEnabled {
                    Divider()
                    UniFiSection(useBits: useBits)
                }

                if openWRTEnabled {
                    Divider()
                    OpenWRTSection(useBits: useBits)
                }

                if showDNSSwitcher {
                    Divider()
                    DNSSwitcherSection()
                }

                if showTopApps {
                    Divider()
                    TopAppsSection(
                        topApps: monitor.topApps,
                        useBits: useBits
                    )
                }

                Divider()
                FooterBar()
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                }
            )
        }
        .onPreferenceChange(ContentHeightKey.self) { height in
            contentHeight = height
        }
    }

    private func filteredAdapters(hidden: Set<String>) -> [AdapterStatus] {
        var filtered = AdapterTotalsFilter.visibleAdapters(
            from: monitor.adapters,
            showOtherAdapters: showOtherAdapters,
            showInactive: showInactive,
            graceEnabled: adapterGracePeriodEnabled,
            hidden: hidden,
            graceDeadlines: monitor.adapterGraceDeadlines
        )
        let order = UserDefaults.standard.stringArray(forKey: "adapterOrder") ?? []
        if !order.isEmpty {
            let orderIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            filtered.sort {
                let ai = orderIndex[$0.id] ?? Int.max
                let bi = orderIndex[$1.id] ?? Int.max
                return ai != bi ? ai < bi
                     : $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
        return filtered
    }
}

// MARK: - Total Rates Header

struct TotalRatesHeader: View {
    let totals: RateTotals
    let useBits: Bool

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            NetRateCell(
                icon: "arrow.down",
                label: "Download",
                color: downloadAccentColor(for: theme),
                rate: RateFormatter.formatRate(totals.rxRateBps, useBits: useBits)
            )
            Divider()
            NetRateCell(
                icon: "arrow.up",
                label: "Upload",
                color: uploadAccentColor(for: theme),
                rate: RateFormatter.formatRate(totals.txRateBps, useBits: useBits)
            )
        }
        .padding(.vertical, 10)
    }
}

struct NetRateCell: View {
    let icon: String
    let label: String
    let color: Color
    let rate: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Text(rate)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Adapter Card

struct AdapterCard: View {
    let adapter: AdapterStatus
    let useBits: Bool
    var customName: String? = nil
    let isReconnecting: Bool
    var onReconnect: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme
    @State private var showWifiDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: adapterIcon())
                    .font(.system(size: 12))
                    .foregroundStyle(adapter.isUp ? Color.primary : Color.secondary)
                    .frame(width: 16)
                Text(titleText())
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if let onReconnect {
                    if isReconnecting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Button(action: onReconnect) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Reconnect")
                    }
                }
                if adapter.type == .wifi, let detail = adapter.wifiDetail {
                    Button { showWifiDetail.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Wi-Fi Details")
                    .popover(isPresented: $showWifiDetail) {
                        WifiDetailPopover(
                            detail: detail,
                            ssid: adapter.wifiSSID,
                            txRate: adapter.wifiTxRateMbps
                        )
                    }
                }
                let link = linkText()
                if !link.isEmpty {
                    Text(link)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(downloadAccentColor(for: theme))
                    Text(RateFormatter.formatRate(adapter.rxRateBps, useBits: useBits))
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(uploadAccentColor(for: theme))
                    Text(RateFormatter.formatRate(adapter.txRateBps, useBits: useBits))
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
                Spacer()
                let mode = modeText()
                if !mode.isEmpty {
                    Text(mode)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background {
            if let c = theme.cardColor {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quinary)
            }
        }
    }

    private func adapterIcon() -> String {
        switch adapter.type {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .other: return "network"
        }
    }

    private func titleText() -> String {
        if let c = customName, !c.isEmpty { return c }
        if adapter.type == .wifi, let ssid = adapter.wifiSSID, !ssid.isEmpty { return ssid }
        return adapter.displayName
    }

    private func linkText() -> String {
        if adapter.type == .wifi {
            return RateFormatter.formatMbps(adapter.wifiTxRateMbps)
        }
        if adapter.type == .ethernet {
            return RateFormatter.formatLinkSpeed(adapter.linkSpeedBps, useBits: true)
        }
        return ""
    }

    private func modeText() -> String {
        switch adapter.type {
        case .wifi:
            guard let mode = adapter.wifiMode else { return "Wi-Fi" }
            if mode.contains("6 GHz") { return "6 GHz" }
            if mode.contains("5 GHz") { return "5 GHz" }
            if mode.contains("2.4") { return "2.4 GHz" }
            return "Wi-Fi"
        case .ethernet:
            return "Ethernet"
        case .other:
            return ""
        }
    }
}

// MARK: - Wi-Fi Detail Popover

struct WifiDetailPopover: View {
    let detail: WifiDetail
    let ssid: String?
    let txRate: Double?

    @State private var copiedBSSID = false

    private var snr: Int? {
        guard let rssi = detail.rssi, let noise = detail.noise else { return nil }
        return rssi - noise
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let phyMode = detail.phyMode {
                detailRow("Standard", phyMode)
            }
            if let security = detail.security {
                detailRow("Security", security)
            }
            if let chNum = detail.channelNumber {
                let width = detail.channelWidth ?? ""
                let channelStr = width.isEmpty ? "Ch \(chNum)" : "Ch \(chNum) (\(width))"
                detailRow("Channel", channelStr)
            }
            if let rssi = detail.rssi {
                detailRow("RSSI", "\(rssi) dBm")
            }
            if let noise = detail.noise {
                detailRow("Noise", "\(noise) dBm")
            }
            if let snr {
                detailRow("SNR", "\(snr) dB")
            }
            if let ssid, !ssid.isEmpty {
                detailRow("ESSID", ssid)
            }
            if let bssid = detail.bssid {
                HStack(spacing: 4) {
                    Text("BSSID")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    Text(bssid)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bssid, forType: .string)
                        withAnimation(.easeInOut(duration: 0.15)) { copiedBSSID = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeInOut(duration: 0.15)) { copiedBSSID = false }
                        }
                    } label: {
                        Image(systemName: copiedBSSID ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(copiedBSSID ? .green : .secondary)
                            .frame(width: 14)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let rate = txRate, rate > 0 {
                detailRow("Tx Rate", "\(Int(rate)) Mbps")
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer()
        }
    }
}

// MARK: - IP Address Section

struct IPAddressSection: View {
    let externalIP: String
    let internalIP: String
    let gatewayIP: String

    var body: some View {
        VStack(spacing: 2) {
            IPRow(label: "External", ip: externalIP, icon: "globe")
            IPRow(label: "Internal", ip: internalIP, icon: "network")
            IPRow(label: "Router", ip: gatewayIP, icon: "wifi.router")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct IPRow: View {
    let label: String
    let ip: String
    let icon: String

    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            Text(ip)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ip, forType: .string)
                withAnimation(.easeInOut(duration: 0.15)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeInOut(duration: 0.15)) { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(copied ? .green : .secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .disabled(ip == "—")
        }
    }
}

// MARK: - Connection Status Section

struct ConnectionStatusSection: View {
    let externalIP: String
    let internalIP: String
    let gatewayIP: String
    let adapters: [AdapterStatus]
    let countryCode: String

    private var activeVPNs: [AdapterStatus] {
        let vpnIPs = Self.vpnInterfaceIPs()
        return adapters.filter { adapter in
            guard adapter.type == .other, adapter.isUp else { return false }
            guard adapter.isTunnelInterface else { return false }
            return vpnIPs[adapter.id] != nil
        }
    }

    private static func vpnInterfaceIPs() -> [String: String] {
        var result: [String: String] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return result }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current?.pointee {
            defer { current = entry.ifa_next }
            guard let sa = entry.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.ifa_name)
            guard AdapterClassifier.isTunnelInterface(named: name) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &hostname, socklen_t(NI_MAXHOST),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = hostname.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if !ip.isEmpty { result[name] = ip }
        }
        return result
    }

    var body: some View {
        HStack(spacing: 0) {
            ConnectionNode(icon: "laptopcomputer", label: "Internal", detail: internalIP, color: .blue)
            ConnectionArrow()
            ConnectionNode(icon: "wifi.router", label: "Router", detail: gatewayIP, color: .orange)
            ConnectionArrow()
            if !activeVPNs.isEmpty {
                vpnNode
                ConnectionArrow()
            }
            ConnectionNode(icon: "globe", label: "External", detail: externalIP, color: .green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var vpnNode: some View {
        let flag = Self.flagEmoji(for: countryCode)
        if activeVPNs.count == 1 {
            let vpn = activeVPNs[0]
            ConnectionNode(icon: "lock.shield", label: vpn.displayName, detail: vpn.id, color: .purple, flag: flag)
        } else {
            let names = activeVPNs.map(\.id).joined(separator: ", ")
            ConnectionNode(icon: "lock.shield", label: "\(activeVPNs.count) VPNs", detail: names, color: .purple, flag: flag)
        }
    }

    private static func flagEmoji(for code: String) -> String? {
        let code = code.uppercased()
        guard code.count == 2, code.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.isAlphabetic }) else { return nil }
        let base: UInt32 = 0x1F1E6 - 0x41 // regional indicator A
        let scalars = code.unicodeScalars.compactMap { UnicodeScalar(base + $0.value) }
        guard scalars.count == 2 else { return nil }
        return String(scalars.map { Character($0) })
    }
}

struct ConnectionNode: View {
    let icon: String
    let label: String
    let detail: String
    let color: Color
    var flag: String? = nil

    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(detail, forType: .string)
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.15)) { copied = false }
            }
        } label: {
            VStack(spacing: 3) {
                if copied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14))
                        .foregroundStyle(.green)
                } else if let flag {
                    Text(flag)
                        .font(.system(size: 16))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                }
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(0.12))
            )
        }
        .buttonStyle(.borderless)
        .disabled(detail == "—")
    }
}

struct ConnectionArrow: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 14)
    }
}

// MARK: - Top Apps Section

struct TopAppsSection: View {
    let topApps: [AppTraffic]
    let useBits: Bool

    private var maxTotal: Double {
        topApps.map { $0.rxRateBps + $0.txRateBps }.max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Top Apps")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            ZStack(alignment: .topLeading) {
                if topApps.isEmpty {
                    Text("Gathering data…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                } else {
                    VStack(spacing: 2) {
                        ForEach(topApps) { app in
                            AppTrafficRow(app: app, useBits: useBits, maxTotal: maxTotal)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
            .frame(height: 166, alignment: .top)
            .clipped()
        }
    }
}

struct AppTrafficRow: View {
    let app: AppTraffic
    let useBits: Bool
    let maxTotal: Double

    @Environment(\.appTheme) private var theme

    private var total: Double { app.rxRateBps + app.txRateBps }
    private var fraction: Double { maxTotal > 0 ? min(1, total / maxTotal) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(app.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8))
                            .foregroundStyle(downloadAccentColor(for: theme))
                        Text(RateFormatter.formatRate(app.rxRateBps, useBits: useBits))
                            .font(.system(size: 10))
                            .monospacedDigit()
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 8))
                            .foregroundStyle(uploadAccentColor(for: theme))
                        Text(RateFormatter.formatRate(app.txRateBps, useBits: useBits))
                            .font(.system(size: 10))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.quaternary)
                        .frame(height: 3)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(downloadAccentColor(for: theme).opacity(0.6))
                        .frame(width: geo.size.width * fraction, height: 3)
                }
            }
            .frame(height: 3)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Popover Resize Handle

struct PopoverResizeHandle: View {
    @State private var dragStartHeight: CGFloat = 0
    @State private var currentViewHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(.quaternary)
                .frame(width: 36, height: 3)
                .padding(.vertical, 3)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(
            GeometryReader { geo in
                Color.clear.onAppear {
                    // Walk up to find the popover window height
                    if let window = geo.frame(in: .global).origin.y as CGFloat? {
                        _ = window // just triggers the geometry read
                    }
                }
                .onChange(of: geo.frame(in: .global)) { _ in
                    // Track the window for drag start
                }
            }
        )
        .gesture(
            DragGesture()
                .onChanged { value in
                    if dragStartHeight == 0 {
                        let saved = UserDefaults.standard.double(forKey: "popoverHeight")
                        if saved > 0 {
                            dragStartHeight = saved
                        } else {
                            // Find the popover window's current height
                            let popoverHeight = NSApp.windows
                                .filter { $0.isVisible && $0.level.rawValue > NSWindow.Level.normal.rawValue }
                                .compactMap { $0.contentView?.frame.height }
                                .max() ?? 500
                            dragStartHeight = popoverHeight
                        }
                    }
                    // Dragging down = positive translation = taller popover
                    let newHeight = max(200, dragStartHeight + value.translation.height)
                    UserDefaults.standard.set(newHeight, forKey: "popoverHeight")
                }
                .onEnded { _ in
                    dragStartHeight = 0
                }
        )
        .onTapGesture(count: 2) {
            // Double-tap resets to auto (natural content size)
            UserDefaults.standard.set(0.0, forKey: "popoverHeight")
        }
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Fritz!Box Bandwidth Section

struct FritzBoxSection: View {
    let useBits: Bool

    @EnvironmentObject private var monitor: NetworkMonitor
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fritz!Box")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if let error = monitor.fritzBoxError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else if let fb = monitor.fritzBox {
                VStack(spacing: 4) {
                    FritzBoxRateRow(
                        icon: "arrow.down",
                        label: "Download",
                        rate: fb.rxRateBps,
                        maxRate: monitor.fritzBoxMaxDown,
                        color: downloadAccentColor(for: theme),
                        useBits: useBits
                    )
                    FritzBoxRateRow(
                        icon: "arrow.up",
                        label: "Upload",
                        rate: fb.txRateBps,
                        maxRate: monitor.fritzBoxMaxUp,
                        color: uploadAccentColor(for: theme),
                        useBits: useBits
                    )
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else {
                Text("Connecting…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }
}

struct FritzBoxRateRow: View {
    let icon: String
    let label: String
    let rate: Double
    let maxRate: UInt64
    let color: Color
    let useBits: Bool

    private var fraction: Double {
        guard maxRate > 0 else { return 0 }
        // maxRate from TR-064 is in bits/s, rate is in bytes/s
        return min(1.0, (rate * 8.0) / Double(maxRate))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 12)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(RateFormatter.formatRate(rate, useBits: useBits))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                if maxRate > 0 {
                    Text("/ \(formatMaxRate())")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            if maxRate > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(.quaternary)
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color.opacity(0.6))
                            .frame(width: geo.size.width * fraction, height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
    }

    private func formatMaxRate() -> String {
        // maxRate is in bits/s from TR-064
        let bps = Double(maxRate)
        if useBits {
            if bps >= 1_000_000_000 { return String(format: "%.0f Gb/s", bps / 1_000_000_000) }
            if bps >= 1_000_000 { return String(format: "%.0f Mb/s", bps / 1_000_000) }
            return String(format: "%.0f Kb/s", bps / 1_000)
        } else {
            let bytesPerSec = bps / 8.0
            if bytesPerSec >= 1_000_000_000 { return String(format: "%.0f GB/s", bytesPerSec / 1_000_000_000) }
            if bytesPerSec >= 1_000_000 { return String(format: "%.0f MB/s", bytesPerSec / 1_000_000) }
            return String(format: "%.0f KB/s", bytesPerSec / 1_000)
        }
    }
}

// MARK: - UniFi Bandwidth Section

struct UniFiSection: View {
    let useBits: Bool

    @EnvironmentObject private var monitor: NetworkMonitor
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("UniFi")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Experimental")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.orange, in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if let error = monitor.unifiError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else if let data = monitor.unifi {
                VStack(spacing: 4) {
                    RouterRateRow(
                        icon: "arrow.down",
                        label: "Download",
                        rate: data.rxRateBps,
                        maxRateMbps: data.maxDownstreamMbps,
                        color: downloadAccentColor(for: theme),
                        useBits: useBits
                    )
                    RouterRateRow(
                        icon: "arrow.up",
                        label: "Upload",
                        rate: data.txRateBps,
                        maxRateMbps: data.maxUpstreamMbps,
                        color: uploadAccentColor(for: theme),
                        useBits: useBits
                    )
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else {
                Text("Connecting…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - OpenWRT Bandwidth Section

struct OpenWRTSection: View {
    let useBits: Bool

    @EnvironmentObject private var monitor: NetworkMonitor
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("OpenWRT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Experimental")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.orange, in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if let error = monitor.openWRTError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else if let data = monitor.openWRT {
                VStack(spacing: 4) {
                    RouterRateRow(
                        icon: "arrow.down",
                        label: "Download",
                        rate: data.rxRateBps,
                        maxRateMbps: data.linkSpeedMbps,
                        color: downloadAccentColor(for: theme),
                        useBits: useBits
                    )
                    RouterRateRow(
                        icon: "arrow.up",
                        label: "Upload",
                        rate: data.txRateBps,
                        maxRateMbps: data.linkSpeedMbps,
                        color: uploadAccentColor(for: theme),
                        useBits: useBits
                    )
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else {
                Text("Gathering data…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - Shared Router Rate Row

struct RouterRateRow: View {
    let icon: String
    let label: String
    let rate: Double
    let maxRateMbps: UInt64
    let color: Color
    let useBits: Bool

    private var fraction: Double {
        guard maxRateMbps > 0 else { return 0 }
        // maxRateMbps is in Mbps, rate is in bytes/s → convert rate to Mbps
        let rateMbps = (rate * 8.0) / 1_000_000.0
        return min(1.0, rateMbps / Double(maxRateMbps))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 12)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(RateFormatter.formatRate(rate, useBits: useBits))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                if maxRateMbps > 0 {
                    Text("/ \(formatMaxRate())")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            if maxRateMbps > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(.quaternary)
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color.opacity(0.6))
                            .frame(width: geo.size.width * fraction, height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
    }

    private func formatMaxRate() -> String {
        // maxRateMbps is in Mbps
        let mbps = Double(maxRateMbps)
        if useBits {
            if mbps >= 1_000 { return String(format: "%.0f Gb/s", mbps / 1_000) }
            return String(format: "%.0f Mb/s", mbps)
        } else {
            let mbytesPerSec = mbps / 8.0
            if mbytesPerSec >= 1_000 { return String(format: "%.0f GB/s", mbytesPerSec / 1_000) }
            return String(format: "%.0f MB/s", mbytesPerSec)
        }
    }
}

// MARK: - DNS Switcher Section

struct DNSSwitcherSection: View {
    @EnvironmentObject private var monitor: NetworkMonitor

    private var presets: [DNSPreset] { NetworkMonitor.allDNSPresets() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DNS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            VStack(spacing: 2) {
                ForEach(presets) { preset in
                    DNSPresetRow(
                        preset: preset,
                        isActive: monitor.activeDNSPresetID == preset.id,
                        isChanging: monitor.dnsChanging,
                        onSelect: { monitor.applyDNS(preset: preset) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }
}

struct DNSPresetRow: View {
    let preset: DNSPreset
    let isActive: Bool
    let isChanging: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? .green : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name)
                        .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                    if !preset.servers.isEmpty {
                        Text(preset.servers.joined(separator: ", "))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Automatic (DHCP)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isActive && isChanging {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.borderless)
        .disabled(isActive || isChanging)
    }
}

// MARK: - Footer

struct FooterBar: View {
    @EnvironmentObject private var monitor: NetworkMonitor

    var body: some View {
        HStack {
            Button {
                PreferencesWindowController.shared.show(monitor: monitor)
            } label: {
                Label("Preferences", systemImage: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                AboutWindowController.shared.show()
            } label: {
                Label("About", systemImage: "info.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
