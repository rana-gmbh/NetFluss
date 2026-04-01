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
        window.setContentSize(NSSize(width: 420, height: 820))
        window.minSize = NSSize(width: 420, height: 400)
        window.maxSize = NSSize(width: 600, height: 10000)
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
        panel.setContentSize(NSSize(width: 300, height: 200))
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

struct AddDNSPanelView: View {
    let editingPreset: DNSPreset?
    let onSave: (DNSPreset) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var primary: String = ""
    @State private var secondary: String = ""

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
            }
        }
    }

    private func save() {
        let trimName = name.trimmingCharacters(in: .whitespaces)
        let trimPrimary = primary.trimmingCharacters(in: .whitespaces)
        let trimSecondary = secondary.trimmingCharacters(in: .whitespaces)
        var servers = [trimPrimary]
        if !trimSecondary.isEmpty { servers.append(trimSecondary) }
        onSave(DNSPreset(
            id: editingPreset?.id ?? UUID().uuidString,
            name: trimName,
            servers: servers,
            isBuiltIn: false
        ))
    }
}
