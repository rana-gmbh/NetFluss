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

/// The one window a new install gets. A menu bar app opens nothing by itself, so
/// without this there is no sign it started, and nothing says that statistics and
/// Top Apps are there but off.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?

    /// Whether this Mac has never run NetFluss. Has to be read before anything
    /// else writes a setting: an existing user always has some.
    static var isFirstLaunch: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return UserDefaults.standard.persistentDomain(forName: bundleID)?.isEmpty ?? true
    }

    func show(onOpenPreferences: @escaping () -> Void) {
        let view = LocalizedRoot {
            WelcomeView(
                onOpenPreferences: { [weak self] in
                    self?.window?.close()
                    onOpenPreferences()
                },
                onDone: { [weak self] in self?.window?.close() }
            )
        }
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.text("Welcome to NetFluss")
        window.styleMask = [.titled, .closable]
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
        let closing = notification.object as? NSWindow
        // Released a moment later: AppKit is still using the window during this
        // call, as the other window controllers here also allow for.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            closing?.delegate = nil
            closing?.contentViewController = nil
            if self?.window === closing { self?.window = nil }
        }
    }
}

struct WelcomeView: View {
    let onOpenPreferences: () -> Void
    let onDone: () -> Void

    @AppStorage("collectStatistics") private var collectStatistics = false
    @AppStorage("showTopApps") private var showTopApps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LText("Welcome to NetFluss")
                .font(.title2.weight(.semibold))
            LText("Your live network speed is now in the menu bar. Click it for the details. The gear button there opens Preferences, Statistics, Speed Test and more.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $collectStatistics) { LText("Collect historical statistics") }
                Toggle(isOn: $showTopApps) { LText("Show top apps by network usage") }
            }
            .padding(.vertical, 2)

            LText("DNS switching and VPN use a small helper. NetFluss asks for it the first time you need it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(action: onOpenPreferences) { LText("Preferences…") }
                Button(action: onDone) { LText("Done") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
