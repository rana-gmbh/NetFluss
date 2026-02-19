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

struct PreferencesView: View {
    @AppStorage("refreshInterval") private var refreshInterval: Double = 1.0
    @AppStorage("showInactive") private var showInactive: Bool = false
    @AppStorage("showOtherAdapters") private var showOtherAdapters: Bool = false
    @AppStorage("useBits") private var useBits: Bool = false
    @AppStorage("showTopApps") private var showTopApps: Bool = false
    @AppStorage("uploadColor") private var uploadColor: String = "green"
    @AppStorage("downloadColor") private var downloadColor: String = "blue"
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
                LabeledContent("Upload ↑") {
                    ColorSwatchPicker(selection: $uploadColor)
                }
                LabeledContent("Download ↓") {
                    ColorSwatchPicker(selection: $downloadColor)
                }
            }

            Section("Top Apps") {
                Toggle("Show top apps (uses nettop)", isOn: $showTopApps)
                if showTopApps {
                    Text("If this shows no data, macOS may restrict nettop access on your system.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 540)
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
