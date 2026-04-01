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
        // PreferencesWindowController manages its own NSWindow; this scene
        // is required by SwiftUI but produces no visible UI.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()
    }
}
