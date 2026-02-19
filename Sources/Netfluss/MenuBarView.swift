import SwiftUI
import AppKit

struct MenuBarLabelView: View {
    @EnvironmentObject private var monitor: NetworkMonitor
    @AppStorage("refreshInterval") private var refreshInterval: Double = 1.0
    @AppStorage("useBits") private var useBits: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("↑ \(RateFormatter.formatRate(monitor.totals.txRateBps, useBits: useBits))")
                .foregroundStyle(.green)
            Text("↓ \(RateFormatter.formatRate(monitor.totals.rxRateBps, useBits: useBits))")
                .foregroundStyle(.blue)
        }
        .font(.system(size: 10, weight: .medium))
        .monospacedDigit()
        .task {
            monitor.start(interval: refreshInterval)
        }
        .onChange(of: refreshInterval) { newValue in
            monitor.start(interval: newValue)
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var monitor: NetworkMonitor
    @AppStorage("showInactive") private var showInactive: Bool = false
    @AppStorage("showOtherAdapters") private var showOtherAdapters: Bool = false
    @AppStorage("useBits") private var useBits: Bool = false
    @AppStorage("showTopApps") private var showTopApps: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            TotalRatesHeader(totals: monitor.totals, useBits: useBits)

            Divider()

            let adapters = filteredAdapters()
            if adapters.isEmpty {
                Text("No active adapters")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                VStack(spacing: 6) {
                    ForEach(adapters) { adapter in
                        AdapterCard(adapter: adapter, useBits: useBits)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            Divider()
            IPAddressSection(
                externalIP: monitor.externalIP,
                internalIP: monitor.internalIP
            )

            if showTopApps {
                Divider()
                TopAppsSection(
                    topApps: monitor.topApps,
                    error: monitor.topAppsError,
                    useBits: useBits
                )
            }

            Divider()
            FooterBar()
        }
    }

    private func filteredAdapters() -> [AdapterStatus] {
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenAdapters") ?? [])
        return monitor.adapters.filter { adapter in
            if !showOtherAdapters, adapter.type == .other { return false }
            if !showInactive, adapter.rxRateBps == 0, adapter.txRateBps == 0, adapter.isUp == false { return false }
            if hidden.contains(adapter.id) { return false }
            return true
        }
    }
}

// MARK: - Total Rates Header

struct TotalRatesHeader: View {
    let totals: RateTotals
    let useBits: Bool

    var body: some View {
        HStack(spacing: 0) {
            NetRateCell(
                icon: "arrow.down",
                label: "Download",
                color: .blue,
                rate: RateFormatter.formatRate(totals.rxRateBps, useBits: useBits)
            )
            Divider()
            NetRateCell(
                icon: "arrow.up",
                label: "Upload",
                color: .green,
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
                        .foregroundStyle(.blue)
                    Text(RateFormatter.formatRate(adapter.rxRateBps, useBits: useBits))
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.green)
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
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func adapterIcon() -> String {
        switch adapter.type {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .other: return "network"
        }
    }

    private func titleText() -> String {
        if adapter.type == .wifi, let ssid = adapter.wifiSSID, !ssid.isEmpty {
            return ssid
        }
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

    var body: some View {
        VStack(spacing: 2) {
            IPRow(label: "External", ip: externalIP, icon: "globe")
            IPRow(label: "Internal", ip: internalIP, icon: "network")
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
    let error: String?
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

            if topApps.isEmpty {
                Text(error.map { "Error: \($0)" } ?? "Gathering data…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
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
    }
}

struct AppTrafficRow: View {
    let app: AppTraffic
    let useBits: Bool
    let maxTotal: Double

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
                            .foregroundStyle(.blue)
                        Text(RateFormatter.formatRate(app.rxRateBps, useBits: useBits))
                            .font(.system(size: 10))
                            .monospacedDigit()
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 8))
                            .foregroundStyle(.green)
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
                        .fill(.blue.opacity(0.6))
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
