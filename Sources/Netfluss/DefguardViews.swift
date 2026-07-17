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

/// Preferences → VPN → Defguard: enroll an instance and (Phase 1) run the TOTP
/// MFA flow. Backed by DefguardManager's mock client for now.
struct DefguardSection: View {
    @EnvironmentObject private var defguard: DefguardManager
    @State private var showAddInstance = false

    var body: some View {
        Section {
            Button { showAddInstance = true } label: { LText("Add Defguard instance…") }
            LText("Connect to a Defguard VPN using device enrollment and TOTP two-factor authentication. Defguard runs over WireGuard.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(defguard.profiles) { profile in
                DefguardProfileRow(profile: profile)
            }
        } header: {
            LText("Defguard")
        }
        .sheet(isPresented: $showAddInstance) {
            AddDefguardSheet()
        }
    }
}

/// One enrolled instance: its locations, a connect button, and the live MFA
/// status. Presents the TOTP prompt while the manager is awaiting a code.
private struct DefguardProfileRow: View {
    let profile: DefguardProfile
    @EnvironmentObject private var defguard: DefguardManager

    private var isThisProfileBusy: Bool {
        switch defguard.mfa {
        case .starting(let id), .awaitingCode(let id, _), .verifying(let id), .authenticated(let id):
            return id == profile.id
        default: return false
        }
    }

    private var showTOTPPrompt: Bool {
        if case .awaitingCode(let id, _) = defguard.mfa { return id == profile.id }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.instance.name).font(.system(size: 12, weight: .medium))
                    Text(profile.instance.instanceURL).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if let location = profile.locations.first {
                    Button(L10n.text("Connect")) { defguard.connect(profile, location: location) }
                        .disabled(isThisProfileBusy)
                }
                Button {
                    defguard.deleteProfile(profile)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(L10n.text("Remove"))
            }
            statusLine
        }
        .sheet(isPresented: Binding(get: { showTOTPPrompt }, set: { if !$0 { defguard.cancelMFA() } })) {
            DefguardTOTPSheet(profile: profile)
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch defguard.mfa {
        case .starting(let id) where id == profile.id, .verifying(let id) where id == profile.id:
            Text(L10n.text("Authenticating…")).font(.caption).foregroundStyle(.secondary)
        case .authenticated(let id) where id == profile.id:
            Label(L10n.text("Authenticated"), systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }
}

/// Enrollment: instance URL + enrollment token → enroll this device.
struct AddDefguardSheet: View {
    @EnvironmentObject private var defguard: DefguardManager
    @Environment(\.dismiss) private var dismiss

    @State private var instanceURL = ""
    @State private var token = ""
    @State private var deviceName = Host.current().localizedName ?? "Mac"
    @State private var isEnrolling = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LText("Add Defguard instance").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                field("Instance URL", text: $instanceURL, placeholder: "https://vpn.example.com")
                field("Enrollment token", text: $token, placeholder: "")
                field("Device name", text: $deviceName, placeholder: "Mac")
            }
            LText("Paste the enrollment URL and token from Defguard (Enrollment / Onboarding). This registers this Mac as a device; your WireGuard key stays in the Keychain.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { dismiss() }
                Button(L10n.text("Enroll")) { enroll() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isEnrolling || instanceURL.isEmpty || token.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func enroll() {
        isEnrolling = true
        errorText = nil
        Task {
            let result = await defguard.enroll(instanceURL: instanceURL, token: token, deviceName: deviceName)
            isEnrolling = false
            switch result {
            case .success: dismiss()
            case .failure(let error): errorText = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LText(label).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("", text: text, prompt: placeholder.isEmpty ? nil : Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }
}

/// TOTP prompt shown while the manager awaits a 2FA code during connect.
struct DefguardTOTPSheet: View {
    let profile: DefguardProfile
    @EnvironmentObject private var defguard: DefguardManager
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LText("Two-factor authentication").font(.headline)
            LText("Enter the 6-digit code from your authenticator app.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("", text: $code, prompt: Text(verbatim: "000000"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 18, design: .monospaced))
                .labelsHidden()
                .onChange(of: code) { newValue in
                    code = String(newValue.filter(\.isNumber).prefix(6))
                }
            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { defguard.cancelMFA(); dismiss() }
                Button(L10n.text("Verify")) { defguard.submitCode(code, for: profile); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.count < 6)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
