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
import UniformTypeIdentifiers

// MARK: - Popover section

/// Compact VPN control in the popover: pick a profile + server and connect.
struct VPNSectionView: View {
    let useBits: Bool
    @EnvironmentObject private var vpn: VPNManager
    @EnvironmentObject private var monitor: NetworkMonitor
    @State private var selectedProfileID: UUID?

    private var currentProfile: VPNProfile? {
        if let id = selectedProfileID, let p = vpn.profiles.first(where: { $0.id == id }) { return p }
        if let activeID = vpn.status.profileID, let p = vpn.profiles.first(where: { $0.id == activeID }) { return p }
        return vpn.profiles.first
    }

    private func isActive(_ profile: VPNProfile) -> Bool {
        vpn.status.profileID == profile.id && vpn.status.state.isActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "VPN")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            if vpn.profiles.isEmpty {
                LText("No VPN profiles. Add one in Preferences → VPN.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else if let profile = currentProfile {
                content(for: profile)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func content(for profile: VPNProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if vpn.profiles.count > 1 {
                Picker(selection: Binding(get: { profile.id }, set: { selectedProfileID = $0 })) {
                    ForEach(vpn.profiles) { Text($0.name).tag($0.id) }
                } label: { EmptyView() }
                .labelsHidden()
            }

            if profile.servers.count > 1 {
                Picker(selection: serverBinding(profile)) {
                    ForEach(Array(profile.servers.enumerated()), id: \.offset) { idx, server in
                        Text(server.label).tag(idx)
                    }
                } label: { EmptyView() }
                .labelsHidden()
                .disabled(isActive(profile))
            }

            HStack(spacing: 8) {
                statusDot(profile)
                Text(statusText(profile))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(L10n.text(isActive(profile) ? "Disconnect" : "Connect")) {
                    if isActive(profile) { vpn.disconnect() } else { vpn.connect(profile) }
                }
                .controlSize(.small)
                .disabled(vpn.status.state.isBusy)
            }

            if isActive(profile), vpn.status.state == .connected {
                // Exit location: flag + country + public IP (from the external-IP
                // lookup, refreshed on connect), then the assigned tunnel IP.
                HStack(spacing: 6) {
                    if let flag = Self.flagEmoji(monitor.externalIPCountryCode) {
                        Text(flag).font(.system(size: 12))
                    }
                    if let country = Self.countryName(monitor.externalIPCountryCode) {
                        Text(country).font(.system(size: 11))
                    }
                    if monitor.externalIP != "—" {
                        Text(monitor.externalIP)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if let ip = vpn.status.assignedIP {
                    Text(verbatim: "Tunnel \(ip)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if vpn.status.profileID == profile.id, case .failed(let message) = vpn.status.state {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private static func flagEmoji(_ code: String) -> String? {
        guard code.count == 2 else { return nil }
        let base: UInt32 = 0x1F1E6
        var scalars = String.UnicodeScalarView()
        for u in code.uppercased().unicodeScalars {
            guard u.value >= 65, u.value <= 90, let s = UnicodeScalar(base + u.value - 65) else { return nil }
            scalars.append(s)
        }
        return String(scalars)
    }

    private static func countryName(_ code: String) -> String? {
        guard code.count == 2 else { return nil }
        return Locale.current.localizedString(forRegionCode: code.uppercased())
    }

    private func serverBinding(_ profile: VPNProfile) -> Binding<Int> {
        Binding(
            get: { profile.selectedServerIndex },
            set: { vpn.selectServer($0, for: profile) }
        )
    }

    @ViewBuilder
    private func statusDot(_ profile: VPNProfile) -> some View {
        let color: Color = {
            guard vpn.status.profileID == profile.id else { return .secondary }
            switch vpn.status.state {
            case .connected: return .green
            case .connecting, .reconnecting, .disconnecting: return .yellow
            case .failed: return .red
            case .idle: return .secondary
            }
        }()
        Circle().fill(color).frame(width: 7, height: 7)
    }

    private func statusText(_ profile: VPNProfile) -> String {
        guard vpn.status.profileID == profile.id else { return L10n.text("Not connected") }
        switch vpn.status.state {
        case .idle: return L10n.text("Not connected")
        case .connecting: return L10n.text("Connecting…")
        case .reconnecting: return L10n.text("Reconnecting…")
        case .disconnecting: return L10n.text("Disconnecting…")
        case .connected: return L10n.text("Connected")
        case .failed: return L10n.text("Failed")
        }
    }
}

// MARK: - Preferences pane content

/// Form sections for managing VPN profiles (rendered inside the Preferences Form).
struct VPNPreferencesContent: View {
    @EnvironmentObject private var vpn: VPNManager
    @AppStorage("showVPN") private var showVPN: Bool = false
    @State private var importError: String?
    @State private var importWarning: String?
    @State private var nativeServices: [NativeVPN.Service] = []
    @State private var showAddIKEv2 = false

    var body: some View {
        Section {
            Toggle(isOn: $showVPN) { LText("Show VPN in popover") }
            Button { importProfile(kind: .openVPN) } label: { LText("Import OpenVPN profile…") }
            Button { importProfile(kind: .wireGuard) } label: { LText("Import WireGuard profile…") }
            LText("Import a single config file, or a folder or .zip of them (e.g. a provider's router profiles). Each config becomes a selectable server.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let importError {
                Text(importError).font(.caption).foregroundStyle(.red)
            }
            if let importWarning {
                Text(importWarning).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            LText("VPN")
        }

        Section {
            if nativeServices.isEmpty {
                LText("No system VPNs found. Configure one in System Settings → VPN, or install a provider configuration profile below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(nativeServices) { service in
                        Button("\(service.name) — \(service.kind)") { vpn.addNativeProfile(service: service) }
                    }
                } label: { LText("Add system VPN…") }
            }
            Button { showAddIKEv2 = true } label: { LText("Add IKEv2 VPN…") }
            Button { installMobileconfig() } label: { LText("Install configuration profile (.mobileconfig)…") }
            Button { nativeServices = vpn.nativeServices() } label: { LText("Refresh system VPNs") }
        } header: {
            LText("System VPN (IKEv2 / IPsec / L2TP)")
        }
        .onAppear { nativeServices = vpn.nativeServices() }
        .sheet(isPresented: $showAddIKEv2) {
            AddIKEv2Sheet { nativeServices = vpn.nativeServices() }
        }

        if !vpn.profiles.isEmpty {
            Section {
                ForEach(vpn.profiles) { profile in
                    VPNProfileRow(profile: profile)
                }
            } header: {
                LText("Profiles")
            }
        }
    }

    private func installMobileconfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let t = UTType(filenameExtension: "mobileconfig") { panel.allowedContentTypes = [t] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ProfileInstaller.present(url)
    }

    private func importProfile(kind: VPNProtocolKind) {
        importError = nil
        importWarning = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let ext = kind == .openVPN ? "ovpn" : "conf"
        var types: [UTType] = [.zip, .folder]
        if let t = UTType(filenameExtension: ext) { types.append(t) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch kind {
            case .openVPN: importWarning = try vpn.importOpenVPNProfile(from: url).warnings.first
            case .wireGuard: try vpn.importWireGuardProfile(from: url)
            case .ikev2: break
            }
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// One profile entry in the Preferences list: server selection, credentials, delete.
struct VPNProfileRow: View {
    let profile: VPNProfile
    @EnvironmentObject private var vpn: VPNManager
    @State private var editedName = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showCredentials = false
    @State private var savedNote = false

    /// DNS presets from NetFluss's DNS section, excluding "automatic" (no servers).
    private var dnsPresets: [DNSPreset] {
        NetworkMonitor.allDNSPresets().filter { !$0.servers.isEmpty }
    }

    /// This profile's position in the ordered list (for the move buttons).
    private var profileIndex: Int? {
        vpn.profiles.firstIndex(where: { $0.id == profile.id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("", text: $editedName, prompt: Text(L10n.text("Name")))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .labelsHidden()
                        .onSubmit { vpn.rename(profile, to: editedName) }
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if vpn.profiles.count > 1 {
                    Button { vpn.moveProfile(profile, up: true) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled((profileIndex ?? 0) == 0)
                    .help("Move up")
                    Button { vpn.moveProfile(profile, up: false) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled((profileIndex ?? 0) >= vpn.profiles.count - 1)
                    .help("Move down")
                }
                Button(role: .destructive) { vpn.deleteProfile(profile) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            if profile.servers.count > 1 {
                Picker(selection: Binding(
                    get: { profile.selectedServerIndex },
                    set: { vpn.selectServer($0, for: profile) }
                )) {
                    ForEach(Array(profile.servers.enumerated()), id: \.offset) { idx, server in
                        Text(server.label).tag(idx)
                    }
                } label: { LText("Server") }
            }

            if supportsAutoReconnect {
                Toggle(isOn: Binding(
                    get: { profile.options.autoReconnect },
                    set: { vpn.setAutoReconnect($0, for: profile) }
                )) {
                    LText("Reconnect automatically")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
            }

            Toggle(isOn: Binding(
                get: { profile.options.connectOnLaunch },
                set: { vpn.setConnectOnLaunch($0, for: profile) }
            )) {
                LText("Connect when NetFluss starts")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: Binding(
                get: { profile.options.useProfileDNS },
                set: { vpn.setUseProfileDNS($0, for: profile) }
            )) {
                LText("Use custom DNS while connected")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            if profile.options.useProfileDNS {
                Picker(selection: Binding(
                    get: { profile.options.dnsPresetID ?? "" },
                    set: { vpn.setProfileDNSPreset($0.isEmpty ? nil : $0, for: profile) }
                )) {
                    Text(L10n.text("Choose a DNS preset")).tag("")
                    ForEach(dnsPresets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                } label: { EmptyView() }
                .labelsHidden()
                .font(.caption)
            }

            if profile.requiresCredentials {
                DisclosureGroup(isExpanded: $showCredentials) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("", text: $username, prompt: Text(L10n.text("Username")))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SecureField("", text: $password, prompt: Text(L10n.text("Password")))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Button { saveCredentials() } label: { LText("Save credentials") }
                            if savedNote {
                                LText("Saved").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } label: {
                    LText(vpn.hasStoredCredentials(profile) ? "Credentials stored" : "Credentials required")
                        .font(.caption)
                        .foregroundStyle(vpn.hasStoredCredentials(profile) ? Color.secondary : Color.orange)
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear { editedName = profile.name }
    }

    private var subtitle: String {
        if profile.kind == .ikev2 {
            return "System VPN · \(profile.nativeServiceName ?? profile.kind.displayName)"
        }
        return "\(profile.kind.displayName) · \(profile.servers.count) server(s)"
    }

    /// Auto-reconnect is offered only where NetFluss can detect a drop: OpenVPN
    /// (management socket), WireGuard (interface poll), and NEVPNManager IKEv2.
    /// Native scutil-managed services have no drop signal, so the toggle is hidden.
    private var supportsAutoReconnect: Bool {
        switch profile.kind {
        case .openVPN, .wireGuard: return true
        case .ikev2: return profile.ikev2Server != nil
        }
    }

    private func saveCredentials() {
        vpn.setCredentials(
            for: profile,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password
        )
        password = ""
        savedNote = true
    }
}

// MARK: - Add IKEv2 sheet

/// Form to enter IKEv2 (username/password) details, generate a .mobileconfig, and
/// hand it to macOS to install. After approval the service appears under
/// "Add system VPN…".
struct AddIKEv2Sheet: View {
    var onInstalled: () -> Void
    @EnvironmentObject private var vpn: VPNManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var server = ""
    @State private var remoteID = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LText("Add IKEv2 VPN").font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                field("Name", text: $name, placeholder: "My VPN")
                field("Server (host or IP)", text: $server, placeholder: "vpn.example.com")
                field("Remote ID", text: $remoteID, placeholder: "vpn.example.com")
                field("Username", text: $username, placeholder: "")
                secureField("Password", text: $password)
            }

            LText("Creates an IKEv2 profile NetFluss connects directly (username/password). The password is stored in your Keychain. If the server uses a private CA, trust its certificate in Keychain Access first.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { dismiss() }
                Button(L10n.text("Add")) { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || server.isEmpty || remoteID.isEmpty || username.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LText(label).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("", text: text, prompt: placeholder.isEmpty ? nil : Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func secureField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LText(label).font(.system(size: 11)).foregroundStyle(.secondary)
            SecureField("", text: text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .labelsHidden()
        }
    }

    private func create() {
        vpn.addIKEv2Profile(name: name, server: server, remoteID: remoteID, username: username, password: password)
        onInstalled()
        dismiss()
    }
}

// MARK: - Profile installation

/// Hands a .mobileconfig to macOS for installation. Modern macOS no longer shows
/// an install dialog on open — it queues the profile and the user must approve it
/// in System Settings — so we also reveal the file and open the profiles pane.
enum ProfileInstaller {
    static func present(_ url: URL) {
        NSWorkspace.shared.open(url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let pane = URL(string: "x-apple.systempreferences:com.apple.preferences.configurationprofiles") {
                NSWorkspace.shared.open(pane)
            }
        }
    }
}
