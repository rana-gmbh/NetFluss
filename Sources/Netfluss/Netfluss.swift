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

@main
struct NetFlussApp: App {
    // AppDelegate owns AppState so that StatusBarController (which calls
    // NSStatusBar) is created inside applicationDidFinishLaunching — after
    // the window-server connection is established.  Initialising it earlier
    // (e.g. as a @StateObject) causes an NSCGSPanic / EXC_BAD_INSTRUCTION
    // crash on Intel Macs running macOS 13.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // PreferencesWindowController manages its own NSWindow; this scene only
        // exists because SwiftUI requires at least one. It is not as invisible
        // as it looks: on launch macOS puts its empty window on screen in front
        // of everything, so AppDelegate closes it — see dismissStraySettingsWindow().
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Preferences…") {
                        NotificationCenter.default.post(name: .showPreferences, object: nil)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var preferencesObserver: NSObjectProtocol?
    private var terminationAnswered = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let firstLaunch = WelcomeWindowController.isFirstLaunch
        AppIconController.shared.start()
        appState = AppState()
        dismissStraySettingsWindow()
        if firstLaunch {
            WelcomeWindowController.shared.show { [weak self] in self?.appState?.showPreferences() }
        }
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .showPreferences,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appState?.showPreferences()
            }
        }

    }

    /// Close the empty window SwiftUI opens for the `Settings` scene at launch.
    ///
    /// A menu bar app owns no windows at startup, and the real preferences live
    /// in an NSWindow of their own, so this one is pure noise — it appeared in
    /// front of whatever the user was doing. Matched by identifier rather than
    /// title, which is localized, and which would also match the five
    /// NSStatusBarWindows that must stay open.
    ///
    /// Run twice: the window is usually already up by the time this is called,
    /// but on a slower launch it arrives a runloop turn later.
    private func dismissStraySettingsWindow() {
        closeSettingsSceneWindows()
        DispatchQueue.main.async { [weak self] in
            self?.closeSettingsSceneWindows()
        }
    }

    private func closeSettingsSceneWindows() {
        for window in NSApp.windows
        where window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" {
            window.close()
        }
    }

    /// Quitting, an update and logging out all pass through here, so a tunnel
    /// running as root never outlives the only app that can stop it. The delay is
    /// a bound, not an expectation: a stuck helper must not hold up a logout.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard VPNManager.shared.hasActiveConnection else { return .terminateNow }
        Task { @MainActor [weak self] in
            await VPNManager.shared.prepareForTermination()
            self?.answerTermination()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.answerTermination()
        }
        return .terminateLater
    }

    private func answerTermination() {
        guard !terminationAnswered else { return }
        terminationAnswered = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.flushStatistics()
        TrafficTimer.shared.persist()
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
    }
}
