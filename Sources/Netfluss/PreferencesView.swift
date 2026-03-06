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
import ServiceManagement

private let colorOptions: [(id: String, label: String)] = [
    ("green", "Green"), ("blue", "Blue"), ("orange", "Orange"), ("yellow", "Yellow"),
    ("teal", "Teal"), ("purple", "Purple"), ("pink", "Pink"), ("white", "White")
]

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
    default:       return .primary
    }
}

struct ColorSwatchPicker: View {
    @Binding var selection: String

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
    @AppStorage("downloadColor") private var downloadColor: String = "blue"
    @AppStorage("theme") private var themeName: String = "system"
    @AppStorage("menuBarFontSize") private var menuBarFontSize: Double = 10.0
    @AppStorage("menuBarFontDesign") private var menuBarFontDesign: String = "monospaced"
    @AppStorage("menuBarMode") private var menuBarMode: String = "rates"
    @AppStorage("connectionStatusMode") private var connectionStatusMode: String = "list"
    @AppStorage("totalsOnlyVisibleAdapters") private var totalsOnlyVisibleAdapters: Bool = false
    @AppStorage("adapterGracePeriodEnabled") private var adapterGracePeriodEnabled: Bool = false
    @AppStorage("adapterGracePeriodSeconds") private var adapterGracePeriodSeconds: Double = 3.0
    @AppStorage("topAppsGracePeriodEnabled") private var topAppsGracePeriodEnabled: Bool = false
    @AppStorage("topAppsGracePeriodSeconds") private var topAppsGracePeriodSeconds: Double = 3.0
    @AppStorage("externalIPv6") private var externalIPv6: Bool = false
    @AppStorage("showDNSSwitcher") private var showDNSSwitcher: Bool = false
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
                Text("When enabled, the Download/Upload summary and menu bar use only adapters that are visible here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Units") {
                Toggle("Display rates in bits per second", isOn: $useBits)
            }

            Section("Appearance") {
                LabeledContent("Theme") {
                    HStack(spacing: 6) {
                        ForEach(AppTheme.all) { t in
                            Button { themeName = t.id } label: {
                                ThemeChip(theme: t, isSelected: themeName == t.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if themeName == "system" {
                    LabeledContent("Upload ↑") {
                        ColorSwatchPicker(selection: $uploadColor)
                    }
                    LabeledContent("Download ↓") {
                        ColorSwatchPicker(selection: $downloadColor)
                    }
                }
                LabeledContent("Menu bar") {
                    Picker("", selection: $menuBarMode) {
                        Text("Rates").tag("rates")
                        Text("Icon").tag("icon")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                }
                LabeledContent("Menu bar size") {
                    HStack(spacing: 8) {
                        Text("\(Int(menuBarFontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                        Stepper("", value: $menuBarFontSize, in: 8...16, step: 1)
                            .labelsHidden()
                    }
                }
                LabeledContent("Menu bar font") {
                    Picker("", selection: $menuBarFontDesign) {
                        Text("Monospaced").tag("monospaced")
                        Text("System").tag("default")
                        Text("Rounded").tag("rounded")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                }
                LabeledContent("IP display") {
                    Picker("", selection: $connectionStatusMode) {
                        Text("List").tag("list")
                        Text("Flow").tag("flow")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                }
                LabeledContent("External IP") {
                    Picker("", selection: $externalIPv6) {
                        Text("IPv4").tag(false)
                        Text("IPv6").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                }
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
                    Text("Switch between DNS providers directly from the popover. Changing DNS requires an admin password.")
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
        .frame(width: 420, height: 880)
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

