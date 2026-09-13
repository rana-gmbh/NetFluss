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
import Combine
import Sparkle

/// In-app updates via Sparkle 2. The feed (`SUFeedURL`) is the `appcast.xml`
/// attached to the latest GitHub release; every update must carry an EdDSA
/// signature matching `SUPublicEDKey` AND the same Developer ID signature as
/// the running app. Sparkle shows the release notes and lets the user choose
/// Install / Skip / Remind Me Later, then replaces the app and relaunches it.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    /// False for unbundled dev runs and for builds without the public EdDSA
    /// key — Sparkle would reject every update there, so it isn't started and
    /// "Check for Updates" falls back to the GitHub releases page.
    @Published private(set) var isAvailable = false

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    private static let releasesURL = URL(string: "https://github.com/rana-gmbh/NetFluss/releases/latest")!

    var lastUpdateCheckDate: Date? {
        isAvailable ? controller.updater.lastUpdateCheckDate : nil
    }

    func start() {
        guard !isAvailable else { return }
        let bundle = Bundle.main
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard bundle.bundleURL.pathExtension == "app", !publicKey.isEmpty else { return }

        let updater = controller.updater
        // Our own preference drives Sparkle's schedule. Setting it explicitly
        // also stops Sparkle from asking for permission on the second launch.
        updater.automaticallyChecksForUpdates = Self.automaticChecksPreference
        do {
            try updater.start()
        } catch {
            NSLog("NetFluss: Sparkle updater failed to start: \(error.localizedDescription)")
            return
        }
        isAvailable = true
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Mirrors Preferences → General → "Check for updates automatically".
    func applyAutomaticChecksPreference() {
        guard isAvailable else { return }
        let enabled = Self.automaticChecksPreference
        // Guarded: Sparkle persists this in UserDefaults, and every defaults
        // write comes back here via UserDefaults.didChangeNotification.
        if controller.updater.automaticallyChecksForUpdates != enabled {
            controller.updater.automaticallyChecksForUpdates = enabled
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard isAvailable else {
            NSWorkspace.shared.open(Self.releasesURL)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(sender)
    }

    private static var automaticChecksPreference: Bool {
        UserDefaults.standard.bool(forKey: "automaticUpdateChecksEnabled")
    }
}

extension AppUpdater: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates(_:)) else { return true }
        return !isAvailable || canCheckForUpdates
    }
}

extension AppUpdater: SPUUpdaterDelegate {}

// Sparkle calls its user-driver delegate on the main thread.
extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    // NetFluss is a menu bar (LSUIElement) app, so it is almost never frontmost
    // when a scheduled check finds an update. Opt in to "gentle reminders" and
    // bring the app forward ourselves so Sparkle's window isn't buried behind
    // other apps.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if handleShowingUpdate, !state.userInitiated {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
