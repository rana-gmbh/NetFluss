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
final class NetworkSliceWindowController: NSObject, NSWindowDelegate {
    static let shared = NetworkSliceWindowController()

    private var window: NSWindow?
    private var closingWindows: [NSWindow] = []
    private var manager: NetworkSliceManager?

    func show(monitor: NetworkMonitor) {
        NotificationCenter.default.post(name: .closePopover, object: nil)

        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let manager = self.manager ?? NetworkSliceManager(monitor: monitor)
        self.manager = manager
        manager.start()

        let view = LocalizedRoot {
            NetworkSliceView()
                .environmentObject(manager)
                .environment(\.appTheme, .system)
        }
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.text("Network Slice")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1040, height: 700))
        window.minSize = NSSize(width: 920, height: 600)
        window.maxSize = NSSize(width: 1600, height: 1400)
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
        manager?.stop()
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
