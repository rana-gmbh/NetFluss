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
final class AboutWindowController: NSObject, NSWindowDelegate {
    static let shared = AboutWindowController()
    private var window: NSWindow?
    private var closingWindows: [NSWindow] = []

    func show() {
        // If the window is already visible, just raise it.
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        // The window may have been closed — discard the stale reference
        // and create a fresh one so UpdateChecker resets to idle.
        window = nil

        let hosting = NSHostingController(rootView: AboutView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "About Netfluss"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.animationBehavior = .none
        win.delegate = self
        win.setContentSize(NSSize(width: 300, height: 460))
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
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
