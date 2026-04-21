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

import AppKit
import ServiceManagement
import SwiftUI

private let colorOptions: [(id: String, label: String)] = [
    ("green", "Green"), ("blue", "Blue"), ("orange", "Orange"),
    ("teal", "Teal"), ("purple", "Purple"), ("pink", "Pink"), ("white", "White"), ("black", "Black")
]

private let appearanceControlWidth: CGFloat = 260

private func swatchColor(_ name: String) -> Color {
    switch name {
    case "green":  return .green
    case "blue":   return .blue
    case "orange": return .orange
    case "yellow": return .yellow
    case "teal":   return .teal
    case "purple": return .purple
    case "pink":   return .pink
    case "white":  return Color(.white)
    case "black":  return Color(.black)
    default:       return .primary
    }
}

struct ColorSwatchPicker: View {
    @Binding var selection: String
    @Binding var customHex: String
    @State private var isShowingCustomPicker = false

    private var customColorBinding: Binding<Color> {
        Binding(
            get: {
                if let color = NSColor(hex: customHex) {
                    return Color(nsColor: color)
                }
                return swatchColor(selection)
            },
            set: { newColor in
                guard let hex = NSColor(newColor).usingColorSpace(.deviceRGB)?.rgbHexString else { return }
                customHex = hex
                selection = "custom"
            }
        )
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(colorOptions, id: \.id) { option in
                Button {
                    selection = option.id
                } label: {
                    ZStack {
                        Circle()
                            .fill(swatchColor(option.id))
                            .frame(width: 18, height: 18)
                        if selection == option.id {
                            Circle()
                                .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                                .frame(width: 18, height: 18)
                            Circle()
                                .strokeBorder(.primary.opacity(0.3), lineWidth: 0.5)
                                .frame(width: 18, height: 18)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .help(option.label)
            }

            Button {
                isShowingCustomPicker = true
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            AngularGradient(
                                colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red],
                                center: .center
                            )
                        )
                        .frame(width: 18, height: 18)
                    Circle()
                        .strokeBorder(selection == "custom" ? .white.opacity(0.9) : .primary.opacity(0.18), lineWidth: selection == "custom" ? 2 : 1)
                        .frame(width: 18, height: 18)
                    if selection == "custom" {
                        Circle()
                            .strokeBorder(.primary.opacity(0.3), lineWidth: 0.5)
                            .frame(width: 18, height: 18)
                    }
                }
            }
            .buttonStyle(.borderless)
            .help("Custom color")
            .popover(isPresented: $isShowingCustomPicker, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Custom Color")
                        .font(.headline)
                    ColorPicker("Choose color", selection: customColorBinding, supportsOpacity: false)
                    HStack {
                        Spacer()
                        Button("Done") {
                            isShowingCustomPicker = false
                        }
                    }
                }
                .padding(12)
                .frame(width: 190)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct TrailingPreferenceControl<Content: View>: View {
    let width: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 12)
            content()
                .frame(width: width, alignment: .trailing)
        }
    }
}

struct ThemeChip: View {
    let theme: AppTheme
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 3) {
                Circle()
                    .fill(theme.downloadColor)
                    .frame(width: 8, height: 8)
                Circle()
                    .fill(theme.uploadColor)
                    .frame(width: 8, height: 8)
            }
            Text(theme.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textPrimary ?? .primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.backgroundColor ?? Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
        )
    }
}

private enum PreferencePane: String, CaseIterable, Identifiable {
    case general
    case adapters
    case statistics
    case appearance
    case topApps
    case dns
    case router

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .adapters:
            return "Adapters"
        case .statistics:
            return "Statistics"
        case .appearance:
            return "Appearance"
        case .topApps:
            return "Top Apps"
        case .dns:
            return "DNS"
        case .router:
            return "Router"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .adapters:
            return "network"
        case .statistics:
            return "chart.bar.xaxis"
        case .appearance:
            return "paintpalette"
        case .topApps:
            return "list.number"
        case .dns:
            return "server.rack"
        case .router:
            return "wifi.router"
        }
    }
}

struct PreferencesView: View {
    @AppStorage("refreshInterval") private var refreshInterval: Double = 1.0
    @AppStorage("showInactive") private var showInactive: Bool = false
    @AppStorage("showOtherAdapters") private var showOtherAdapters: Bool = false
    @AppStorage("useBits") private var useBits: Bool = false
    @AppStorage("showTopApps") private var showTopApps: Bool = false
    @AppStorage("uploadColor") private var uploadColor: String = "green"
    @AppStorage("uploadColorHex") private var uploadColorHex: String = ""
    @AppStorage("downloadColor") private var downloadColor: String = "blue"
    @AppStorage("downloadColorHex") private var downloadColorHex: String = ""
    @AppStorage("menuBarUploadTextColor") private var menuBarUploadTextColor: String = "green"
    @AppStorage("menuBarUploadTextColorHex") private var menuBarUploadTextColorHex: String = ""
    @AppStorage("menuBarDownloadTextColor") private var menuBarDownloadTextColor: String = "blue"
    @AppStorage("menuBarDownloadTextColorHex") private var menuBarDownloadTextColorHex: String = ""
    @AppStorage("menuBarFontSize") private var menuBarFontSize: Double = 10.0
    @AppStorage("menuBarFontDesign") private var menuBarFontDesign: String = "monospaced"
    @AppStorage("menuBarMode") private var menuBarMode: String = "rates"
    @AppStorage("menuBarIconSymbol") private var menuBarIconSymbol: String = "network"
    @AppStorage("menuBarPinnedUnit") private var menuBarPinnedUnit: String = "auto"
    @AppStorage("menuBarDecimals") private var menuBarDecimals: Int = 0
    @AppStorage("connectionStatusMode") private var connectionStatusMode: String = "list"
    @AppStorage("totalsOnlyVisibleAdapters") private var totalsOnlyVisibleAdapters: Bool = false
    @AppStorage("excludeTunnelAdaptersFromTotals") private var excludeTunnelAdaptersFromTotals: Bool = false
    @AppStorage("adapterGracePeriodEnabled") private var adapterGracePeriodEnabled: Bool = false
    @AppStorage("adapterGracePeriodSeconds") private var adapterGracePeriodSeconds: Double = 3.0
    @AppStorage("topAppsGracePeriodEnabled") private var topAppsGracePeriodEnabled: Bool = false
    @AppStorage("topAppsGracePeriodSeconds") private var topAppsGracePeriodSeconds: Double = 3.0
    @AppStorage("collectStatistics") private var collectStatistics: Bool = false
    @AppStorage("collectAppStatistics") private var collectAppStatistics: Bool = true
    @AppStorage("externalIPv6") private var externalIPv6: Bool = false
    @AppStorage("showDNSSwitcher") private var showDNSSwitcher: Bool = false
    @AppStorage("fritzBoxEnabled") private var fritzBoxEnabled: Bool = false
    @AppStorage("fritzBoxHost") private var fritzBoxHost: String = ""
    @AppStorage("unifiEnabled") private var unifiEnabled: Bool = false
    @AppStorage("unifiHost") private var unifiHost: String = ""
    @AppStorage("openWRTEnabled") private var openWRTEnabled: Bool = false
    @AppStorage("openWRTHost") private var openWRTHost: String = ""
    @AppStorage("opnsenseEnabled") private var opnsenseEnabled: Bool = false
    @AppStorage("opnsenseHost") private var opnsenseHost: String = ""
    @AppStorage("automaticUpdateChecksEnabled") private var automaticUpdateChecksEnabled: Bool = true
    @AppStorage("appLanguage") private var appLanguage: String = AppLanguage.system.rawValue
    @State private var hiddenAdapters: Set<String> = []
    @State private var adapterNames: [String: String] = [:]
    @State private var adapterOrder: [String] = []
    @State private var draggingID: String? = nil
    @State private var dragBaseOrder: [String] = []
    @State private var renamingAdapter: AdapterStatus? = nil
    @State private var launchAtLogin: Bool = false
    @State private var hiddenApps: [String] = []
    @State private var showHiddenAppsSheet = false
    @State private var customDNSPresets: [DNSPreset] = []
    @State private var hiddenDNSPresets: Set<String> = []
    @State private var dnsPresetOrder: [String] = []
    @State private var dnsDraggingID: String? = nil
    @State private var dnsDragBaseOrder: [String] = []
    @State private var selectedPane: PreferencePane = .general

    @EnvironmentObject private var monitor: NetworkMonitor

    var body: some View {
        VStack(spacing: 0) {
            preferencesToolbar
            Divider()
            Form {
                if selectedPane == .general {
                    Section {
                Picker(selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                } label: {
                    LText("Language")
                }
                LText("System Default follows the language selected in macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                LText("Language")
            }

                    Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: $refreshInterval, in: 0.5...5.0, step: 0.5)
                            .frame(minWidth: 100)
                        Text("\(refreshInterval, specifier: "%.1f") s")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                } label: {
                    LText("Refresh interval")
                }
                Toggle(isOn: $automaticUpdateChecksEnabled) {
                    LText("Check GitHub for updates automatically")
                }
                LText("When enabled, NetFluss checks once per day in the background. The manual Check for Updates button in About stays available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                LText("Update")
            }

                    Section {
                Toggle(isOn: $useBits) {
                    LText("Display rates in bits per second")
                }
            } header: {
                LText("Units")
            }

                    Section {
                Toggle(isOn: Binding(
                    get: { launchAtLogin },
                    set: { enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            // Silently ignore — expected in dev builds outside /Applications
                        }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                )) {
                    LText("Launch at login")
                }
            } header: {
                LText("Launch")
            }
                }

                if selectedPane == .adapters {
                    Section {
                Toggle(isOn: $showInactive) {
                    LText("Show inactive adapters")
                }
                Toggle(isOn: $showOtherAdapters) {
                    LText("Show other adapters (VPN, virtual)")
                }
                Toggle(isOn: $adapterGracePeriodEnabled) {
                    LText("Hide adapters after inactivity")
                }
                if adapterGracePeriodEnabled {
                    LabeledContent {
                        Picker("", selection: $adapterGracePeriodSeconds) {
                            Text("3 s").tag(3.0)
                            Text("5 s").tag(5.0)
                            Text("10 s").tag(10.0)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 160)
                    } label: {
                        LText("Hide after")
                    }
                }
            } header: {
                LText("Adapter Visibility")
            }

                    Section {
                if sortedAdapterRows.isEmpty {
                    LText("No adapters match current filters.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedAdapterRows, id: \.id) { adapter in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .frame(width: 16)
                            Toggle("", isOn: bindingFor(adapter.id)).labelsHidden()
                            Text(adapterDisplayLabel(for: adapter))
                                .lineLimit(1)
                            Spacer()
                            Text(adapter.id)
                                .font(.caption2).foregroundStyle(.tertiary)
                            Button {
                                renamingAdapter = adapter
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .help("Rename")
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentColor.opacity(draggingID == adapter.id ? 0.12 : 0))
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                                .onChanged { value in
                                    if draggingID != adapter.id {
                                        draggingID = adapter.id
                                        dragBaseOrder = sortedAdapterRows.map(\.id)
                                    }
                                    let rowH: CGFloat = 36
                                    let shift = Int((value.translation.height / rowH).rounded())
                                    guard let src = dragBaseOrder.firstIndex(of: adapter.id) else { return }
                                    let dst = max(0, min(dragBaseOrder.count - 1, src + shift))
                                    var newOrder = dragBaseOrder
                                    newOrder.move(fromOffsets: IndexSet(integer: src),
                                                  toOffset: dst > src ? dst + 1 : dst)
                                    if adapterOrder != newOrder { adapterOrder = newOrder }
                                }
                                .onEnded { _ in
                                    UserDefaults.standard.set(adapterOrder, forKey: "adapterOrder")
                                    draggingID = nil
                                }
                        )
                    }
                }

                Toggle(isOn: $totalsOnlyVisibleAdapters) {
                    LText("Only include visible adapters in totals")
                }
                Toggle(isOn: $excludeTunnelAdaptersFromTotals) {
                    LText("Exclude VPN/tunnel adapters from totals")
                }
                LText("When enabled, the Download/Upload summary and menu bar use only adapters that are visible here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LText("Tunnel adapters such as utun, tun, tap, ipsec, and ppp are excluded from totals but remain visible in the adapter list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                LText("Adapters")
            }
                }

                if selectedPane == .statistics {
                    Section {
                Toggle(isOn: $collectStatistics) {
                    LText("Collect historical statistics")
                }
                LText("Disabled by default to avoid extra background work and energy use. When enabled, NetFluss keeps hourly and daily rollups for adapters and optional app traffic analysis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if collectStatistics {
                    Toggle(isOn: $collectAppStatistics) {
                        LText("Collect app statistics")
                    }
                    LText("App statistics are on by default and may increase energy consumption because NetFluss periodically samples per-app network usage in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                LText("Statistics")
            }
                }

                if selectedPane == .appearance {
                    Section {
                LabeledContent {
                    TrailingPreferenceControl(width: appearanceControlWidth) {
                        ColorSwatchPicker(selection: $uploadColor, customHex: $uploadColorHex)
                    }
                } label: {
                    LText("Upload arrow ↑")
                }
                LabeledContent {
                    TrailingPreferenceControl(width: appearanceControlWidth) {
                        ColorSwatchPicker(selection: $downloadColor, customHex: $downloadColorHex)
                    }
                } label: {
                    LText("Download arrow ↓")
                }
                LabeledContent {
                    TrailingPreferenceControl(width: appearanceControlWidth) {
                        ColorSwatchPicker(selection: $menuBarUploadTextColor, customHex: $menuBarUploadTextColorHex)
                    }
                } label: {
                    LText("Upload number ↑")
                }
                LabeledContent {
                    TrailingPreferenceControl(width: appearanceControlWidth) {
                        ColorSwatchPicker(selection: $menuBarDownloadTextColor, customHex: $menuBarDownloadTextColorHex)
                    }
                } label: {
                    LText("Download number ↓")
                }
                LabeledContent {
                    TrailingPreferenceControl(width: appearanceControlWidth) {
                        Picker("", selection: $menuBarMode) {
                            LText("Standard").tag("rates")
                            LText("Unified pill").tag("unified")
                            LText("Dashboard").tag("dashboard")
                            LText("Icon").tag("icon")
                        }
                        .frame(width: 180)
                    }
                } label: {
                    LText("Menu bar icon style")
                }
                if menuBarMode == "icon" {
                    LabeledContent {
                        TrailingPreferenceControl(width: appearanceControlWidth) {
                            Picker("", selection: $menuBarIconSymbol) {
                                ForEach(MenuBarIconLibrary.options) { option in
                                    HStack(spacing: 8) {
                                        if let image = MenuBarIconLibrary.image(for: option.id, pointSize: 14) {
                                            Image(nsImage: image)
                                                .renderingMode(.template)
                                        }
                                        Text(option.label)
                                    }
                                    .tag(option.id)
                                }
                            }
                            .frame(width: 180)
                        }
                    } label: {
                        LText("Menu bar icon")
                    }
                } else {
                    LabeledContent {
                        TrailingPreferenceControl(width: appearanceControlWidth) {
                            HStack(spacing: 8) {
                                Text("\(Int(menuBarFontSize)) pt")
                                    .monospacedDigit()
                                    .frame(width: 36, alignment: .trailing)
                                Stepper("", value: $menuBarFontSize, in: 8...16, step: 1)
                                    .labelsHidden()
                            }
                        }
                    } label: {
                        LText("Menu bar size")
                    }
                    LabeledContent {
                        TrailingPreferenceControl(width: appearanceControlWidth) {
                            Picker("", selection: $menuBarFontDesign) {
                                LText("Monospaced").tag("monospaced")
                                LText("System").tag("default")
                                LText("Rounded").tag("rounded")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                        }
                    } label: {
                        LText("Menu bar font")
                    }
                    LabeledContent {
                        TrailingPreferenceControl(width: appearanceControlWidth) {
                            Picker("", selection: $menuBarPinnedUnit) {
                                LText("Auto").tag("auto")
                                Text(useBits ? "Kb/s" : "KB/s").tag("K")
                                Text(useBits ? "Mb/s" : "MB/s").tag("M")
                                Text(useBits ? "Gb/s" : "GB/s").tag("G")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 250)
                        }
                    } label: {
                        LText("Menu bar unit")
                    }
                    LabeledContent {
                        TrailingPreferenceControl(width: appearanceControlWidth) {
                            Picker("", selection: $menuBarDecimals) {
                                LText("Auto").tag(0)
                                Text("0").tag(10)
                                Text("1").tag(1)
                                Text("2").tag(2)
                                Text("3").tag(3)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                    } label: {
                        LText("Decimals")
                    }
                }
                LText("Dashboard uses router-wide traffic when Fritz!Box, UniFi, OpenWRT, or OPNsense bandwidth is enabled and available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                LText("Appearance")
            }

                    Section {
                LabeledContent {
                    TrailingPreferenceControl(width: appearanceControlWidth) {
                        Picker("", selection: $connectionStatusMode) {
                            LText("List").tag("list")
                            LText("Flow").tag("flow")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                } label: {
                    LText("IP display")
                }
                LabeledContent {
                    TrailingPreferenceControl(width: appearanceControlWidth) {
                        Picker("", selection: $externalIPv6) {
                            Text("IPv4").tag(false)
                            Text("IPv6").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                } label: {
                    LText("External IP")
                }
            } header: {
                LText("IP addresses")
            }
                }

                if selectedPane == .topApps {
                    Section {
                Toggle(isOn: $showTopApps) {
                    LText("Show top apps by network usage")
                }
                if showTopApps {
                    LText("Shows the top 5 processes ranked by current network traffic.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Toggle(isOn: $topAppsGracePeriodEnabled) {
                        LText("Keep apps visible after traffic stops")
                    }
                    if topAppsGracePeriodEnabled {
                        LabeledContent {
                            Picker("", selection: $topAppsGracePeriodSeconds) {
                                Text("3 s").tag(3.0)
                                Text("5 s").tag(5.0)
                                Text("10 s").tag(10.0)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 160)
                        } label: {
                            LText("Visible for")
                        }
                    }
                    HStack {
                        Button("Apps to Hide\(hiddenApps.isEmpty ? "" : " (\(hiddenApps.count))")…") {
                            showHiddenAppsSheet = true
                        }
                    }
                }
            } header: {
                LText("Top Apps")
            }
                }

                if selectedPane == .dns {
                    Section {
                Toggle(isOn: $showDNSSwitcher) {
                    LText("Show DNS switcher in popover")
                }
                if showDNSSwitcher {
                    LText("DNS changes and Ethernet reconnects install a privileged helper the first time. macOS may ask for administrator approval and, on some systems, additional approval in System Settings.")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    ForEach(sortedDNSPresets) { preset in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .frame(width: 16)
                            Toggle("", isOn: dnsBindingFor(preset.id)).labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.name)
                                    .lineLimit(1)
                                if !preset.servers.isEmpty {
                                    Text(preset.servers.joined(separator: ", "))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if !preset.isBuiltIn {
                                Button {
                                    AddDNSWindowController.shared.showEdit(preset: preset) { [self] updated in
                                        if let idx = customDNSPresets.firstIndex(where: { $0.id == updated.id }) {
                                            customDNSPresets[idx] = updated
                                        }
                                        saveCustomDNSPresets()
                                    }
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.borderless)
                                .help("Edit")
                                Button {
                                    customDNSPresets.removeAll { $0.id == preset.id }
                                    saveCustomDNSPresets()
                                    dnsPresetOrder.removeAll { $0 == preset.id }
                                    UserDefaults.standard.set(dnsPresetOrder, forKey: "dnsPresetOrder")
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .help("Delete")
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentColor.opacity(dnsDraggingID == preset.id ? 0.12 : 0))
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                                .onChanged { value in
                                    if dnsDraggingID != preset.id {
                                        dnsDraggingID = preset.id
                                        dnsDragBaseOrder = sortedDNSPresets.map(\.id)
                                    }
                                    let rowH: CGFloat = 36
                                    let shift = Int((value.translation.height / rowH).rounded())
                                    guard let src = dnsDragBaseOrder.firstIndex(of: preset.id) else { return }
                                    let dst = max(0, min(dnsDragBaseOrder.count - 1, src + shift))
                                    var newOrder = dnsDragBaseOrder
                                    newOrder.move(fromOffsets: IndexSet(integer: src),
                                                  toOffset: dst > src ? dst + 1 : dst)
                                    if dnsPresetOrder != newOrder { dnsPresetOrder = newOrder }
                                }
                                .onEnded { _ in
                                    UserDefaults.standard.set(dnsPresetOrder, forKey: "dnsPresetOrder")
                                    dnsDraggingID = nil
                                }
                        )
                    }

                    Button("Add Custom DNS…") {
                        AddDNSWindowController.shared.show { [self] preset in
                            customDNSPresets.append(preset)
                            saveCustomDNSPresets()
                            // Add to order so it appears at the end
                            if !dnsPresetOrder.contains(preset.id) {
                                dnsPresetOrder.append(preset.id)
                                UserDefaults.standard.set(dnsPresetOrder, forKey: "dnsPresetOrder")
                            }
                        }
                    }
                }
            } header: {
                LText("DNS Switcher")
            }
                }

                if selectedPane == .router {
                    Section {
                Toggle(isOn: $fritzBoxEnabled) {
                    LText("Show Fritz!Box bandwidth in popover")
                }
                if fritzBoxEnabled {
                    LabeledContent {
                        HStack(spacing: 6) {
                            if fritzBoxHost.isEmpty {
                                Text(monitor.gatewayIP)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                LText("(auto)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(fritzBoxHost)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                            }
                            Button("Edit…") {
                                EditFritzBoxHostController.shared.show(currentHost: fritzBoxHost) { newHost in
                                    fritzBoxHost = newHost
                                }
                            }
                        }
                    } label: {
                        LText("Router address")
                    }
                    LText("Queries your Fritz!Box via TR-064 (no authentication needed for bandwidth data). Auto uses the current default gateway. Set a fixed address if your Fritz!Box is reachable at a different IP. Port 49000 must be reachable.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    if let error = monitor.fritzBoxError {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 11))
                            Text(error)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }
            } header: {
                LText("Fritz!Box Bandwidth")
            }
                }

                if selectedPane == .router {
                    Section {
                Toggle(isOn: $unifiEnabled) {
                    LText("Show UniFi bandwidth in popover")
                }
                if unifiEnabled {
                    LabeledContent {
                        HStack(spacing: 6) {
                            if unifiHost.isEmpty {
                                Text(monitor.gatewayIP)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                LText("(auto)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(unifiHost)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                            }
                            Button("Edit…") {
                                EditRouterHostController.shared.show(
                                    title: "UniFi Address",
                                    placeholder: "Router IP (auto-detect)",
                                    currentHost: unifiHost
                                ) { newHost in
                                    unifiHost = newHost
                                }
                            }
                        }
                    } label: {
                        LText("Router address")
                    }
                    LabeledContent {
                        HStack(spacing: 6) {
                            let host = unifiHost.isEmpty ? monitor.gatewayIP : unifiHost
                            if UniFiMonitor.loadCredentials(host: host) != nil {
                                LText("Configured")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            } else {
                                LText("Not set")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.orange)
                            }
                            Button("Edit…") {
                                EditRouterCredentialsController.shared.show(
                                    title: "UniFi Credentials",
                                    host: host
                                ) { username, password in
                                    UniFiMonitor.saveCredentials(host: host, username: username, password: password)
                                }
                            }
                        }
                    } label: {
                        LText("Credentials")
                    }
                    LText("Queries your UniFi gateway via its local API (HTTPS). Requires a local admin account on the UniFi controller.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    if let error = monitor.unifiError {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 11))
                            Text(error)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }
            } header: {
                LText("UniFi Bandwidth")
            }
                }

                if selectedPane == .router {
                    Section {
                Toggle(isOn: $openWRTEnabled) {
                    LText("Show OpenWRT bandwidth in popover")
                }
                if openWRTEnabled {
                    LabeledContent {
                        HStack(spacing: 6) {
                            if openWRTHost.isEmpty {
                                Text(monitor.gatewayIP)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                LText("(auto)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(openWRTHost)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                            }
                            Button("Edit…") {
                                EditRouterHostController.shared.show(
                                    title: "OpenWRT Address",
                                    placeholder: "Router IP or URL (auto uses gateway)",
                                    currentHost: openWRTHost
                                ) { newHost in
                                    openWRTHost = newHost
                                }
                            }
                        }
                    } label: {
                        LText("Router address")
                    }
                    LabeledContent {
                        HStack(spacing: 6) {
                            let host = openWRTHost.isEmpty ? monitor.gatewayIP : openWRTHost
                            if OpenWRTMonitor.loadCredentials(host: host) != nil {
                                LText("Configured")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            } else {
                                LText("Not set")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.orange)
                            }
                            Button("Edit…") {
                                EditRouterCredentialsController.shared.show(
                                    title: "OpenWRT Credentials",
                                    host: host
                                ) { username, password in
                                    OpenWRTMonitor.saveCredentials(host: host, username: username, password: password)
                                }
                            }
                        }
                    } label: {
                        LText("Credentials")
                    }
                    LText("Queries your OpenWRT router via ubus JSON-RPC over HTTPS or HTTP. Auto uses the current default gateway, which may be the wrong router on dual-router setups. Set a fixed OpenWRT IP or URL if needed. Requires the router's admin credentials and the uhttpd-mod-ubus package.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    if let error = monitor.openWRTError {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 11))
                            Text(error)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }
            } header: {
                LText("OpenWRT Bandwidth")
            }
                }

                if selectedPane == .router {
                    Section {
                Toggle(isOn: $opnsenseEnabled) {
                    LText("Show OPNsense bandwidth in popover")
                }
                if opnsenseEnabled {
                    LabeledContent {
                        HStack(spacing: 6) {
                            if opnsenseHost.isEmpty {
                                Text(monitor.gatewayIP)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                LText("(auto)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(opnsenseHost)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                            }
                            Button("Edit…") {
                                EditRouterHostController.shared.show(
                                    title: "OPNsense Address",
                                    placeholder: "Router IP or URL (auto uses gateway)",
                                    currentHost: opnsenseHost
                                ) { newHost in
                                    opnsenseHost = newHost
                                }
                            }
                        }
                    } label: {
                        LText("Router address")
                    }
                    LabeledContent {
                        HStack(spacing: 6) {
                            let host = opnsenseHost.isEmpty ? monitor.gatewayIP : opnsenseHost
                            if OPNsenseMonitor.loadCredentials(host: host) != nil {
                                LText("Configured")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            } else {
                                LText("Not set")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.orange)
                            }
                            Button("Edit…") {
                                EditOPNsenseCredentialsController.shared.show(host: host)
                            }
                        }
                    } label: {
                        LText("API Credentials")
                    }
                    LText("Queries your OPNsense router via REST API over HTTPS or HTTP. Auto uses the current default gateway. Requires API key and secret configured in OPNsense.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    if let error = monitor.opnsenseError {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 11))
                            Text(error)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }
            } header: {
                LText("OPNsense Bandwidth")
            }
                }

            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            hiddenAdapters = Set(UserDefaults.standard.stringArray(forKey: "hiddenAdapters") ?? [])
            adapterNames = loadAdapterNames()
            adapterOrder = UserDefaults.standard.stringArray(forKey: "adapterOrder") ?? []
            hiddenApps = UserDefaults.standard.stringArray(forKey: "hiddenApps") ?? []
            customDNSPresets = loadCustomDNSPresets()
            hiddenDNSPresets = Set(UserDefaults.standard.stringArray(forKey: "hiddenDNSPresets") ?? [])
            dnsPresetOrder = UserDefaults.standard.stringArray(forKey: "dnsPresetOrder") ?? []
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .sheet(item: $renamingAdapter) { adapter in
            RenameAdapterSheet(
                adapter: adapter,
                currentName: adapterNames[adapter.id] ?? "",
                onSave: { newName in
                    adapterNames[adapter.id] = newName.isEmpty ? nil : newName
                    saveAdapterNames(adapterNames)
                    renamingAdapter = nil
                },
                onCancel: { renamingAdapter = nil }
            )
        }
        .sheet(isPresented: $showHiddenAppsSheet) {
            HiddenAppsSheet(
                recentAppNames: monitor.recentAppNames,
                hiddenApps: $hiddenApps,
                onDone: { showHiddenAppsSheet = false }
            )
        }
        .onAppear {
            if menuBarMode == "sparkline" {
                menuBarMode = "dashboard"
            }
            if menuBarMode == "icon", menuBarIconSymbol == "network" {
                menuBarIconSymbol = "netfluss"
            }
        }
        .onChange(of: menuBarMode) { newValue in
            if newValue == "icon", menuBarIconSymbol == "network" {
                menuBarIconSymbol = "netfluss"
            }
        }
    }

    private var preferencesToolbar: some View {
        VStack(spacing: 8) {
            LText("Preferences")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(PreferencePane.allCases) { pane in
                        Button {
                            selectedPane = pane
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: pane.systemImage)
                                    .font(.system(size: 24, weight: .medium))
                                    .symbolRenderingMode(.hierarchical)
                                LText(pane.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundColor(selectedPane == pane ? .accentColor : .secondary)
                            .frame(width: 72, height: 62)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(selectedPane == pane ? Color.accentColor.opacity(0.11) : Color.clear)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(L10n.text(pane.title))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }
        }
        .background(.regularMaterial)
    }

    private var adapterRows: [AdapterStatus] {
        monitor.adapters
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .filter { adapter in
                if !showOtherAdapters, adapter.type == .other { return false }
                if !showInactive, adapter.rxRateBps == 0, adapter.txRateBps == 0, adapter.isUp == false { return false }
                return true
            }
    }

    private var sortedAdapterRows: [AdapterStatus] {
        let rows = adapterRows
        if adapterOrder.isEmpty { return rows }
        return rows.sorted {
            let ai = adapterOrder.firstIndex(of: $0.id) ?? Int.max
            let bi = adapterOrder.firstIndex(of: $1.id) ?? Int.max
            return ai != bi ? ai < bi
                 : $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func adapterDisplayLabel(for adapter: AdapterStatus) -> String {
        if let custom = adapterNames[adapter.id], !custom.isEmpty { return custom }
        return adapter.displayName
    }

    private func bindingFor(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !hiddenAdapters.contains(id) },
            set: { isOn in
                if isOn {
                    hiddenAdapters.remove(id)
                } else {
                    hiddenAdapters.insert(id)
                }
                UserDefaults.standard.set(Array(hiddenAdapters), forKey: "hiddenAdapters")
            }
        )
    }

    private func loadAdapterNames() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: "adapterCustomNames"),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private func saveAdapterNames(_ names: [String: String]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(names), forKey: "adapterCustomNames")
    }

    private var allDNSPresets: [DNSPreset] {
        DNSPreset.builtIn + customDNSPresets
    }

    private var sortedDNSPresets: [DNSPreset] {
        let presets = allDNSPresets
        if dnsPresetOrder.isEmpty { return presets }
        return presets.sorted {
            let ai = dnsPresetOrder.firstIndex(of: $0.id) ?? Int.max
            let bi = dnsPresetOrder.firstIndex(of: $1.id) ?? Int.max
            return ai < bi
        }
    }

    private func dnsBindingFor(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !hiddenDNSPresets.contains(id) },
            set: { isOn in
                if isOn {
                    hiddenDNSPresets.remove(id)
                } else {
                    hiddenDNSPresets.insert(id)
                }
                UserDefaults.standard.set(Array(hiddenDNSPresets), forKey: "hiddenDNSPresets")
            }
        )
    }

    private func loadCustomDNSPresets() -> [DNSPreset] {
        guard let data = UserDefaults.standard.data(forKey: "customDNSPresets"),
              let presets = try? JSONDecoder().decode([DNSPreset].self, from: data)
        else { return [] }
        return presets
    }

    private func saveCustomDNSPresets() {
        UserDefaults.standard.set(try? JSONEncoder().encode(customDNSPresets), forKey: "customDNSPresets")
    }

}

// MARK: - Rename Sheet

struct RenameAdapterSheet: View {
    let adapter: AdapterStatus
    let currentName: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename \"\(adapter.displayName)\"")
                .font(.headline)
            TextField("Custom name", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { onSave(text) }
            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(text) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .onAppear { text = currentName }
    }
}

// MARK: - Hidden Apps Sheet

struct HiddenAppsSheet: View {
    let recentAppNames: [String]
    @Binding var hiddenApps: [String]
    let onDone: () -> Void

    private var visibleRecent: [String] {
        recentAppNames.filter { !hiddenApps.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hide Apps")
                .font(.headline)

            Text("Apps that used bandwidth in the last 60 seconds:")
                .font(.caption)
                .foregroundStyle(.secondary)

            if visibleRecent.isEmpty {
                Text("No recent apps detected yet. Keep Top Apps enabled and check back shortly.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(visibleRecent, id: \.self) { name in
                            HStack {
                                Text(name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    hiddenApps.append(name)
                                    UserDefaults.standard.set(hiddenApps, forKey: "hiddenApps")
                                } label: {
                                    Image(systemName: "eye.slash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Hide \(name)")
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            if !hiddenApps.isEmpty {
                Divider()
                Text("Hidden apps:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(hiddenApps, id: \.self) { name in
                            HStack {
                                Text(name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    hiddenApps.removeAll { $0 == name }
                                    UserDefaults.standard.set(hiddenApps, forKey: "hiddenApps")
                                } label: {
                                    Image(systemName: "eye")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.borderless)
                                .help("Show \(name)")
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }

            HStack {
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
