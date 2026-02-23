import SwiftUI

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
    @State private var hiddenAdapters: Set<String> = []

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
            }

            Section("Adapters") {
                if adapterRows.isEmpty {
                    Text("No adapters match current filters.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(adapterRows, id: \.id) { adapter in
                        Toggle(adapter.displayName, isOn: bindingFor(adapter.id))
                    }
                }
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
            }

            Section("Top Apps") {
                Toggle("Show top apps by network usage", isOn: $showTopApps)
                if showTopApps {
                    Text("Shows the top 10 processes ranked by current network traffic.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 640)
        .onAppear {
            hiddenAdapters = Set(UserDefaults.standard.stringArray(forKey: "hiddenAdapters") ?? [])
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
}
