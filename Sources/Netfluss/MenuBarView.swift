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
    @EnvironmentObject private var monitor: NetworkMonitor
    @AppStorage("showInactive") private var showInactive: Bool = false
    @AppStorage("showOtherAdapters") private var showOtherAdapters: Bool = false
    @AppStorage("useBits") private var useBits: Bool = false
    @AppStorage("showTopApps") private var showTopApps: Bool = false
    @AppStorage("theme") private var themeName: String = "system"
    @AppStorage("totalsOnlyVisibleAdapters") private var totalsOnlyVisibleAdapters: Bool = false

    // Height for one adapter card (padding + title row + spacing + rates row) + inter-card spacing.
    // Used to size the scroll area to show exactly 6 cards before scrolling kicks in.
    private static let cardHeight: CGFloat = 58   // per card incl. vertical padding
    private static let cardSpacing: CGFloat = 6   // VStack spacing between cards
    private static let adapterListPadding: CGFloat = 20 // .padding(.vertical, 10) top+bottom
    private static func adapterScrollHeight(for count: Int) -> CGFloat {
        let n = CGFloat(min(count, 6))
        return n * cardHeight + max(0, n - 1) * cardSpacing + adapterListPadding
    }

    var body: some View {
        let theme = AppTheme.named(themeName)
        let adapters = filteredAdapters()
        let headerTotals = totalsOnlyVisibleAdapters ? totals(for: adapters) : monitor.totals
        let customNames = (try? JSONDecoder().decode([String: String].self,
            from: UserDefaults.standard.data(forKey: "adapterCustomNames") ?? Data())) ?? [:]

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
                ScrollView {
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
                .scrollIndicators(adapters.count > 6 ? .visible : .never)
                .frame(height: Self.adapterScrollHeight(for: adapters.count))
            }

            Divider()
            IPAddressSection(
                externalIP: monitor.externalIP,
                internalIP: monitor.internalIP,
                gatewayIP: monitor.gatewayIP
            )

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
        .background(theme.backgroundColor ?? .clear)
        .environment(\.appTheme, theme)
    }

    private var cardSpacing: CGFloat { Self.cardSpacing }

    private func filteredAdapters() -> [AdapterStatus] {
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenAdapters") ?? [])
        var filtered = monitor.adapters.filter { adapter in
            if !showOtherAdapters, adapter.type == .other { return false }
            if !showInactive, adapter.rxRateBps == 0, adapter.txRateBps == 0, adapter.isUp == false { return false }
            if hidden.contains(adapter.id) { return false }
            return true
        }
        let order = UserDefaults.standard.stringArray(forKey: "adapterOrder") ?? []
        if !order.isEmpty {
            filtered.sort {
                let ai = order.firstIndex(of: $0.id) ?? Int.max
                let bi = order.firstIndex(of: $1.id) ?? Int.max
                return ai != bi ? ai < bi
                     : $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
        return filtered
    }

    private func totals(for adapters: [AdapterStatus]) -> RateTotals {
        var rx: Double = 0
        var tx: Double = 0
        for adapter in adapters {
            rx += adapter.rxRateBps
            tx += adapter.txRateBps
        }
        return RateTotals(rxRateBps: rx, txRateBps: tx)
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
                color: theme.downloadColor,
                rate: RateFormatter.formatRate(totals.rxRateBps, useBits: useBits)
            )
            Divider()
            NetRateCell(
                icon: "arrow.up",
                label: "Upload",
                color: theme.uploadColor,
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
                        .foregroundStyle(theme.downloadColor)
                    Text(RateFormatter.formatRate(adapter.rxRateBps, useBits: useBits))
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.uploadColor)
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
                            .foregroundStyle(theme.downloadColor)
                        Text(RateFormatter.formatRate(app.rxRateBps, useBits: useBits))
                            .font(.system(size: 10))
                            .monospacedDigit()
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 8))
                            .foregroundStyle(theme.uploadColor)
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
                        .fill(theme.downloadColor.opacity(0.6))
                        .frame(width: geo.size.width * fraction, height: 3)
                }
            }
            .frame(height: 3)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
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
