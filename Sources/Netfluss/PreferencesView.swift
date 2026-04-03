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

private let menuBarIconOptions: [(symbol: String, label: String)] = [
    ("network", "Network"),
    ("arrow.up.arrow.down", "Arrows"),
    ("wifi", "Wi-Fi"),
    ("antenna.radiowaves.left.and.right", "Antenna")
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

private struct ExperimentalBadge: View {
    var body: some View {
        Text("Experimental")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.orange, in: Capsule())
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
    @AppStorage("externalIPv6") private var externalIPv6: Bool = false
    @AppStorage("showDNSSwitcher") private var showDNSSwitcher: Bool = false
    @AppStorage("useTouchID") private var useTouchID: Bool = true
    @AppStorage("fritzBoxEnabled") private var fritzBoxEnabled: Bool = false
    @AppStorage("fritzBoxHost") private var fritzBoxHost: String = ""
    @AppStorage("unifiEnabled") private var unifiEnabled: Bool = false
    @AppStorage("unifiHost") private var unifiHost: String = ""
    @AppStorage("openWRTEnabled") private var openWRTEnabled: Bool = false
    @AppStorage("openWRTHost") private var openWRTHost: String = ""
    @AppStorage("automaticUpdateChecksEnabled") private var automaticUpdateChecksEnabled: Bool = true
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

    @EnvironmentObject private var monitor: NetworkMonitor

    var body: some View {
        Form {
            Section("Update") {
                LabeledContent("Refresh interval") {
                    HStack(spacing: 8) {
                        Slider(value: $refreshInterval, in: 0.5...5.0, step: 0.5)
                            .frame(minWidth: 100)
                        Text("\(refreshInterval, specifier: "%.1f") s")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Toggle("Check GitHub for updates automatically", isOn: $automaticUpdateChecksEnabled)
                Text("When enabled, NetFluss checks once per day in the background. The manual Check for Updates button in About stays available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show inactive adapters", isOn: $showInactive)
                Toggle("Show other adapters (VPN, virtual)", isOn: $showOtherAdapters)
                Toggle("Hide adapters after inactivity", isOn: $adapterGracePeriodEnabled)
                if adapterGracePeriodEnabled {
                    LabeledContent("Hide after") {
                        Picker("", selection: $adapterGracePeriodSeconds) {
                            Text("3 s").tag(3.0)
                            Text("5 s").tag(5.0)
                            Text("10 s").tag(10.0)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 160)
                    }
                }
            }

            Section("Adapters") {
                if sortedAdapterRows.isEmpty {
                    Text("No adapters match current filters.")
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

                Toggle("Only include visible adapters in totals", isOn: $totalsOnlyVisibleAdapters)
                Toggle("Exclude VPN/tunnel adapters from totals", isOn: $excludeTunnelAdaptersFromTotals)
                Text("When enabled, the Download/Upload summary and menu bar use only adapters that are visible here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Tunnel adapters such as utun, tun, tap, ipsec, and ppp are excluded from totals but remain visible in the adapter list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Units") {
                Toggle("Display rates in bits per second", isOn: $useBits)
            }

            Section("Appearance") {
                LabeledContent("Upload arrow ↑") {
                    TrailingPreferenceControl(width: appearanceControlWidth) {
                        ColorSwatchPicker(selection: $uploadColor, customHex: $uploadColorHex)
                    }
                }
                LabeledContent("Download arrow ↓") {
                    TrailingPreferenceControl(width: appearanceControlWidth) {
                        ColorSwatchPicker(selection: $downloadColor, customHex: $downloadColorHex)
                    }
                }
                LabeledContent("Upload number ↑") {
                    TrailingPreferenceControl(width: appearanceControlWidth) {
                        ColorSwatchPicker(selection: $menuBarUploadTextColor, customHex: $menuBarUploadTextColorHex)
                    }
                }
                LabeledContent("Download number ↓") {
                    TrailingPreferenceControl(width: appearanceControlWidth) {
                        ColorSwatchPicker(selection: $menuBarDownloadTextColor, customHex: $menuBarDownloadTextColorHex)
                    }
                }
                LabeledContent {
                    TrailingPreferenceControl(width: appearanceControlWidth) {
                        Picker("", selection: $menuBarMode) {
                            Text("Standard").tag("rates")
                            Text("Unified pill").tag("unified")
                            Text("Dashboard").tag("dashboard")
                            Text("Icon").tag("icon")
                        }
                        .frame(width: 180)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Menu bar icon style")
                        ExperimentalBadge()
                    }
                }
                if menuBarMode == "icon" {
                    LabeledContent("Menu bar icon") {
                        TrailingPreferenceControl(width: appearanceControlWidth) {
                            Picker("", selection: $menuBarIconSymbol) {
                                ForEach(menuBarIconOptions, id: \.symbol) { option in
                                    Label(option.label, systemImage: option.symbol)
                                        .tag(option.symbol)
                                }
                            }
                            .frame(width: 180)
                        }
                    }
                } else {
                    LabeledContent("Menu bar size") {
                        TrailingPreferenceControl(width: appearanceControlWidth) {
                            HStack(spacing: 8) {
                                Text("\(Int(menuBarFontSize)) pt")
                                    .monospacedDigit()
                                    .frame(width: 36, alignment: .trailing)
                                Stepper("", value: $menuBarFontSize, in: 8...16, step: 1)
                                    .labelsHidden()
                            }
                        }
                    }
                    LabeledContent("Menu bar font") {
                        TrailingPreferenceControl(width: appearanceControlWidth) {
                            Picker("", selection: $menuBarFontDesign) {
                                Text("Monospaced").tag("monospaced")
                                Text("System").tag("default")
                                Text("Rounded").tag("rounded")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                        }
                    }
                    LabeledContent("Menu bar unit") {
                        TrailingPreferenceControl(width: appearanceControlWidth) {
                            Picker("", selection: $menuBarPinnedUnit) {
                                Text("Auto").tag("auto")
                                Text(useBits ? "Kb/s" : "KB/s").tag("K")
                                Text(useBits ? "Mb/s" : "MB/s").tag("M")
                                Text(useBits ? "Gb/s" : "GB/s").tag("G")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 250)
                        }
                    }
                    LabeledContent("Decimals") {
                        TrailingPreferenceControl(width: appearanceControlWidth) {
                            Picker("", selection: $menuBarDecimals) {
                                Text("Auto").tag(0)
                                Text("0").tag(10)
                                Text("1").tag(1)
                                Text("2").tag(2)
                                Text("3").tag(3)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                    }
                }
                LabeledContent("IP display") {
                    TrailingPreferenceControl(width: appearanceControlWidth) {
                        Picker("", selection: $connectionStatusMode) {
                            Text("List").tag("list")
                            Text("Flow").tag("flow")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                }
                LabeledContent("External IP") {
                    TrailingPreferenceControl(width: appearanceControlWidth) {
                        Picker("", selection: $externalIPv6) {
                            Text("IPv4").tag(false)
                            Text("IPv6").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                }
                Text("Dashboard uses router-wide traffic when Fritz!Box, UniFi, or OpenWRT bandwidth is enabled and available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Top Apps") {
                Toggle("Show top apps by network usage", isOn: $showTopApps)
                if showTopApps {
                    Text("Shows the top 5 processes ranked by current network traffic.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Toggle("Keep apps visible after traffic stops", isOn: $topAppsGracePeriodEnabled)
                    if topAppsGracePeriodEnabled {
                        LabeledContent("Visible for") {
                            Picker("", selection: $topAppsGracePeriodSeconds) {
                                Text("3 s").tag(3.0)
                                Text("5 s").tag(5.0)
                                Text("10 s").tag(10.0)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 160)
                        }
                    }
                    HStack {
                        Button("Apps to Hide\(hiddenApps.isEmpty ? "" : " (\(hiddenApps.count))")…") {
                            showHiddenAppsSheet = true
                        }
                    }
                }
            }

            Section("DNS Switcher") {
                Toggle("Show DNS switcher in popover", isOn: $showDNSSwitcher)
                if showDNSSwitcher {
                    Toggle("Use Touch ID for authentication", isOn: $useTouchID)
                    Text("When enabled, Touch ID is used to authenticate DNS changes and Ethernet reconnects. Falls back to admin password if Touch ID is unavailable.")
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
            }

            Section {
                Toggle("Show Fritz!Box bandwidth in popover", isOn: $fritzBoxEnabled)
                if fritzBoxEnabled {
                    LabeledContent("Router address") {
                        HStack(spacing: 6) {
                            if fritzBoxHost.isEmpty {
                                Text(monitor.gatewayIP)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text("(auto)")
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
                    }
                    Text("Queries your Fritz!Box via TR-064 (no authentication needed for bandwidth data). The router must be reachable on port 49000.")
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
                Text("Fritz!Box Bandwidth")
            }

            Section {
                Toggle("Show UniFi bandwidth in popover", isOn: $unifiEnabled)
                if unifiEnabled {
                    LabeledContent("Router address") {
                        HStack(spacing: 6) {
                            if unifiHost.isEmpty {
                                Text(monitor.gatewayIP)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text("(auto)")
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
                    }
                    LabeledContent("Credentials") {
                        HStack(spacing: 6) {
                            let host = unifiHost.isEmpty ? monitor.gatewayIP : unifiHost
                            if UniFiMonitor.loadCredentials(host: host) != nil {
                                Text("Configured")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Not set")
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
                    }
                    Text("Queries your UniFi gateway via its local API (HTTPS). Requires a local admin account on the UniFi controller.")
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
                HStack(spacing: 4) {
                    Text("UniFi Bandwidth")
                    Text("Experimental")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange, in: Capsule())
                }
            }

            Section {
                Toggle("Show OpenWRT bandwidth in popover", isOn: $openWRTEnabled)
                if openWRTEnabled {
                    LabeledContent("Router address") {
                        HStack(spacing: 6) {
                            if openWRTHost.isEmpty {
                                Text(monitor.gatewayIP)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text("(auto)")
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
                                    placeholder: "Router IP (auto-detect)",
                                    currentHost: openWRTHost
                                ) { newHost in
                                    openWRTHost = newHost
                                }
                            }
                        }
                    }
                    LabeledContent("Credentials") {
                        HStack(spacing: 6) {
                            let host = openWRTHost.isEmpty ? monitor.gatewayIP : openWRTHost
                            if OpenWRTMonitor.loadCredentials(host: host) != nil {
                                Text("Configured")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Not set")
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
                    }
                    Text("Queries your OpenWRT router via ubus JSON-RPC (HTTP). Requires the router's admin credentials.")
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
                HStack(spacing: 4) {
                    Text("OpenWRT Bandwidth")
                    Text("Experimental")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange, in: Capsule())
                }
            }

            Section("Launch") {
                Toggle("Launch at login", isOn: Binding(
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
                ))
            }
        }
        .formStyle(.grouped)
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
        }
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
