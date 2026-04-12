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
final class SpeedTestWindowController: NSObject, NSWindowDelegate {
    static let shared = SpeedTestWindowController()

    private var window: NSWindow?
    private var manager: SpeedTestManager?
    private var closingWindows: [NSWindow] = []

    func show(manager: SpeedTestManager, startImmediately: Bool = false, showHistory: Bool = false) {
        NotificationCenter.default.post(name: .closePopover, object: nil)

        self.manager = manager

        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            if showHistory {
                manager.presentHistory()
            } else {
                manager.dismissHistory()
            }
            if startImmediately {
                manager.startWithSelectedProvider()
            }
            return
        }

        let view = SpeedTestView()
            .environmentObject(manager)
            .environment(\.appTheme, .system)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "Speed Test"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let availableFrame = screenFrame.insetBy(dx: 40, dy: 40)
        let minimumWidth = min(SpeedTestView.minimumWindowWidth, availableFrame.width)
        let minimumHeight = min(SpeedTestView.minimumWindowHeight, availableFrame.height)
        let targetWidth = min(SpeedTestView.preferredWindowWidth, availableFrame.width)
        let measuredSize = hosting.sizeThatFits(in: NSSize(width: targetWidth, height: .greatestFiniteMagnitude))
        let preferredHeight = min(SpeedTestView.preferredWindowHeight, availableFrame.height)
        let targetHeight = min(
            max(
                max(measuredSize.height, preferredHeight),
                minimumHeight
            ),
            availableFrame.height
        )
        window.setContentSize(NSSize(width: targetWidth, height: targetHeight))
        window.minSize = NSSize(width: minimumWidth, height: minimumHeight)
        window.maxSize = NSSize(width: 1280, height: 960)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        if showHistory {
            DispatchQueue.main.async {
                manager.presentHistory()
            }
        } else {
            manager.dismissHistory()
        }

        if startImmediately {
            manager.startWithSelectedProvider()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow == window else { return }

        if manager?.phase.isRunning == true || manager?.isAwaitingMLabConsent == true {
            manager?.cancel()
        }
        manager?.dismissHistory()

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
