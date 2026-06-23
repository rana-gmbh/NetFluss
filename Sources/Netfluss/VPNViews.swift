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
                Button(isActive(profile) ? "Disconnect" : "Connect") {
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
        } header: {
            LText("VPN")
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

    private func importProfile(kind: VPNProtocolKind) {
        importError = nil
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
            case .openVPN: try vpn.importOpenVPNProfile(from: url)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("", text: $editedName, prompt: Text(L10n.text("Name")))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .labelsHidden()
                        .onSubmit { vpn.rename(profile, to: editedName) }
                    Text(verbatim: "\(profile.kind.displayName) · \(profile.servers.count) server(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
