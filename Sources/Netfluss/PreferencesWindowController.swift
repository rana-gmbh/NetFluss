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
import SwiftUI

@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindowController()
    private var window: NSWindow?
    private var closingWindows: [NSWindow] = []

    func show(monitor: NetworkMonitor) {
        // Close the popover synchronously before showing the preferences window.
        NotificationCenter.default.post(name: .closePopover, object: nil)

        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = PreferencesView()
            .environmentObject(monitor)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 840, height: 680))
        window.minSize = NSSize(width: 720, height: 520)
        window.maxSize = NSSize(width: 1100, height: 10000)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow == window else { return }
        window = nil
        closingWindows.append(closingWindow)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak closingWindow] in
            guard let self, let closingWindow else { return }
            closingWindow.delegate = nil
            closingWindow.contentViewController = nil
            self.closingWindows.removeAll { $0 === closingWindow }
        }
    }
}

@MainActor
final class AddDNSWindowController {
    static let shared = AddDNSWindowController()
    private var panel: NSPanel?
    private var onSave: ((DNSPreset) -> Void)?

    func show(onSave: @escaping (DNSPreset) -> Void) {
        showPanel(editing: nil, onSave: onSave)
    }

    func showEdit(preset: DNSPreset, onSave: @escaping (DNSPreset) -> Void) {
        showPanel(editing: preset, onSave: onSave)
    }

    private func showPanel(editing preset: DNSPreset?, onSave: @escaping (DNSPreset) -> Void) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        self.onSave = onSave

        let view = AddDNSPanelView(editing: preset) { [weak self] saved in
            onSave(saved)
            self?.close()
        } onCancel: { [weak self] in
            self?.close()
        }
        let hosting = NSHostingController(rootView: view)

        let isEdit = preset != nil
        let panel = NSPanel(contentViewController: hosting)
        panel.title = isEdit ? "Edit Custom DNS" : "Add Custom DNS"
        panel.styleMask = [.titled, .closable, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.setContentSize(NSSize(width: 340, height: 270))
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()

        self.panel = panel
    }

    private func close() {
        panel?.close()
        panel = nil
        onSave = nil
        reactivatePreferencesWindow()
    }
}

private func reactivatePreferencesWindow() {
    // After a panel closes, re-activate the preferences window so it
    // regains key/main status and toggles show the accent color.
    if let window = NSApp.windows.first(where: { $0.title == "Preferences" && $0.isVisible }) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class EditFritzBoxHostController {
    static let shared = EditFritzBoxHostController()
    private var panel: NSPanel?

    func show(currentHost: String, onSave: @escaping (String) -> Void) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = EditFritzBoxHostPanelView(currentHost: currentHost) { [weak self] newHost in
            onSave(newHost)
            self?.close()
        } onCancel: { [weak self] in
            self?.close()
        }
        let hosting = NSHostingController(rootView: view)

        let panel = NSPanel(contentViewController: hosting)
        panel.title = "Fritz!Box Address"
        panel.styleMask = [.titled, .closable, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.setContentSize(NSSize(width: 300, height: 160))
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()

        self.panel = panel
    }

    private func close() {
        panel?.close()
        panel = nil
        reactivatePreferencesWindow()
    }
}

struct EditFritzBoxHostPanelView: View {
    let currentHost: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Fritz!Box Address")
                .font(.headline)
            TextField("Router IP (auto-detect)", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            HStack(spacing: 12) {
                Button("Reset to Auto") {
                    onSave("")
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .onAppear { text = currentHost }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}

// MARK: - Generic Router Host Editor

@MainActor
final class EditRouterHostController {
    static let shared = EditRouterHostController()
    private var panel: NSPanel?

    func show(title: String, placeholder: String, currentHost: String, onSave: @escaping (String) -> Void) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = EditRouterHostPanelView(title: title, placeholder: placeholder, currentHost: currentHost) { [weak self] newHost in
            onSave(newHost)
            self?.close()
        } onCancel: { [weak self] in
            self?.close()
        }
        let hosting = NSHostingController(rootView: view)

        let panel = NSPanel(contentViewController: hosting)
        panel.title = title
        panel.styleMask = [.titled, .closable, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.setContentSize(NSSize(width: 300, height: 160))
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()

        self.panel = panel
    }

    private func close() {
        panel?.close()
        panel = nil
        reactivatePreferencesWindow()
    }
}

struct EditRouterHostPanelView: View {
    let title: String
    let placeholder: String
    let currentHost: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            HStack(spacing: 12) {
                Button("Reset to Auto") {
                    onSave("")
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .onAppear { text = currentHost }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}

// MARK: - Router Credentials Editor

@MainActor
final class EditRouterCredentialsController {
    static let shared = EditRouterCredentialsController()
    private var panel: NSPanel?

    func show(title: String, host: String, onSave: @escaping (String, String) -> Void) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = EditRouterCredentialsPanelView(title: title, host: host) { [weak self] username, password in
            onSave(username, password)
            self?.close()
        } onCancel: { [weak self] in
            self?.close()
        }
        let hosting = NSHostingController(rootView: view)

        let panel = NSPanel(contentViewController: hosting)
        panel.title = title
        panel.styleMask = [.titled, .closable, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.setContentSize(NSSize(width: 320, height: 220))
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()

        self.panel = panel
    }

    private func close() {
        panel?.close()
        panel = nil
        reactivatePreferencesWindow()
    }
}

struct EditRouterCredentialsPanelView: View {
    let title: String
    let host: String
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var username: String = ""
    @State private var password: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
            Text("for \(host)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
        }
        .padding(24)
    }

    private func save() {
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        guard !trimmedUser.isEmpty, !password.isEmpty else { return }
        onSave(trimmedUser, password)
    }
}

// MARK: - OPNsense Credentials Editor

@MainActor
final class EditOPNsenseCredentialsController {
    static let shared = EditOPNsenseCredentialsController()
    private var panel: NSPanel?

    func show(host: String, onSave: @escaping () -> Void = {}) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = EditOPNsenseCredentialsPanelView(host: host) { [weak self] apiKey, apiSecret in
            OPNsenseMonitor.saveCredentials(host: host, apiKey: apiKey, apiSecret: apiSecret)
            onSave()
            self?.close()
        } onCancel: { [weak self] in
            self?.close()
        }
        let hosting = NSHostingController(rootView: view)

        let panel = NSPanel(contentViewController: hosting)
        panel.title = "OPNsense API Credentials"
        panel.styleMask = [.titled, .closable, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.setContentSize(NSSize(width: 340, height: 280))
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()

        self.panel = panel
    }

    private func close() {
        panel?.close()
        panel = nil
        reactivatePreferencesWindow()
    }
}

struct EditOPNsenseCredentialsPanelView: View {
    let host: String
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var apiKey: String = ""
    @State private var apiSecret: String = ""
    @State private var isTesting = false
    @State private var testPassed = false
    @State private var testError: String?

    private var canTest: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !apiSecret.isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("OPNsense API Credentials")
                .font(.headline)
            Text("for \(host)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .disabled(isTesting)
            SecureField("API Secret", text: $apiSecret)
                .textFieldStyle(.roundedBorder)
                .disabled(isTesting)
                .onSubmit { testConnection() }
            Text("Generate these in OPNsense: System → User Management → API")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Test connection status
            if let error = testError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12))
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if testPassed {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                    Text("Connection successful")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isTesting)
                Spacer()
                Button(isTesting ? "Testing…" : "Test Connection") {
                    testConnection()
                }
                .disabled(isTesting || !canTest)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isTesting || !testPassed)
            }
        }
        .padding(24)
        .onAppear {
            if let creds = OPNsenseMonitor.loadCredentials(host: host) {
                apiKey = creds.apiKey
                apiSecret = creds.apiSecret
            }
        }
    }

    private func testConnection() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmedKey.isEmpty, !apiSecret.isEmpty else { return }

        isTesting = true
        testError = nil
        testPassed = false

        Task {
            do {
                try await OPNsenseMonitor.login(host: host, apiKey: trimmedKey, apiSecret: apiSecret)
                await MainActor.run {
                    testPassed = true
                    testError = nil
                    isTesting = false
                }
            } catch {
                let errorMsg: String
                if let opnsenseError = error as? OPNsenseError {
                    switch opnsenseError {
                    case .authFailed:
                        errorMsg = "API key or secret is incorrect (HTTP 401/403)"
                    case .invalidURL:
                        errorMsg = "Invalid router address or URL format"
                    case .httpStatus(let code):
                        errorMsg = "HTTP error \(code) — check the router address and verify the API is enabled"
                    case .parseError:
                        errorMsg = "Router returned unexpected format — verify the API endpoint or check the OPNsense logs (console output has details)"
                    case .requestFailed:
                        errorMsg = "Could not reach router — verify address and network connectivity"
                    case .noWANInterface:
                        errorMsg = "Router responded but WAN interface not found"
                    }
                } else if let urlError = error as? URLError {
                    switch urlError.code {
                    case .timedOut:
                        errorMsg = "Router did not respond in time"
                    case .cannotFindHost:
                        errorMsg = "Could not resolve host — check the address"
                    case .cannotConnectToHost:
                        errorMsg = "Could not connect to router — verify address and network"
                    default:
                        errorMsg = "Network error: \((error as NSError).localizedDescription)"
                    }
                } else {
                    errorMsg = "Error: \((error as NSError).localizedDescription)"
                }
                await MainActor.run {
                    testPassed = false
                    testError = errorMsg
                    isTesting = false
                }
            }
        }
    }

    private func save() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmedKey.isEmpty, !apiSecret.isEmpty, testPassed else { return }
        onSave(trimmedKey, apiSecret)
    }
}

struct AddDNSPanelView: View {
    let editingPreset: DNSPreset?
    let onSave: (DNSPreset) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var primary: String = ""
    @State private var secondary: String = ""
    @State private var tertiary: String = ""
    @State private var quaternary: String = ""

    init(editing preset: DNSPreset? = nil,
         onSave: @escaping (DNSPreset) -> Void,
         onCancel: @escaping () -> Void) {
        self.editingPreset = preset
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var isEditing: Bool { editingPreset != nil }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !primary.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(isEditing ? "Edit Custom DNS" : "Add Custom DNS")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name (e.g. My DNS)", text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField("Primary DNS (e.g. 1.1.1.1)", text: $primary)
                    .textFieldStyle(.roundedBorder)
                TextField("Secondary DNS (optional)", text: $secondary)
                    .textFieldStyle(.roundedBorder)
                TextField("Tertiary DNS (optional)", text: $tertiary)
                    .textFieldStyle(.roundedBorder)
                TextField("Quaternary DNS (optional)", text: $quaternary)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .onAppear {
            if let preset = editingPreset {
                name = preset.name
                primary = preset.servers.first ?? ""
                secondary = preset.servers.count > 1 ? preset.servers[1] : ""
                tertiary = preset.servers.count > 2 ? preset.servers[2] : ""
                quaternary = preset.servers.count > 3 ? preset.servers[3] : ""
            }
        }
    }

    private func save() {
        let trimName = name.trimmingCharacters(in: .whitespaces)
        let servers = [
            primary.trimmingCharacters(in: .whitespaces),
            secondary.trimmingCharacters(in: .whitespaces),
            tertiary.trimmingCharacters(in: .whitespaces),
            quaternary.trimmingCharacters(in: .whitespaces)
        ].filter { !$0.isEmpty }
        onSave(DNSPreset(
            id: editingPreset?.id ?? UUID().uuidString,
            name: trimName,
            servers: servers,
            isBuiltIn: false
        ))
    }
}
