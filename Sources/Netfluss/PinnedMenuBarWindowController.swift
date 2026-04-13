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
final class PinnedMenuBarWindowController: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private var onClose: (() -> Void)?
    private var closingWindows: [NSWindow] = []

    var isVisible: Bool {
        window?.isVisible == true
    }

    func show<Content: View>(
        rootView: Content,
        preferredWidth: CGFloat,
        screenVisibleFrame: CGRect,
        initialFrame: NSRect? = nil,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose

        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = []

        let targetFrame = constrainedFrame(
            initialFrame ?? defaultFrame(preferredWidth: preferredWidth, visibleFrame: screenVisibleFrame),
            to: screenVisibleFrame
        )

        if let window {
            window.contentViewController = hosting
            window.setFrame(targetFrame, display: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(contentViewController: hosting)
        panel.title = "NetFluss"
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.setFrame(targetFrame, display: false)
        panel.minSize = NSSize(width: preferredWidth, height: 260)
        panel.maxSize = NSSize(
            width: max(preferredWidth, screenVisibleFrame.width - 24),
            height: max(260, screenVisibleFrame.height - 24)
        )
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        self.window = panel
    }

    func close() {
        window?.close()
    }

    func bringToFront() {
        guard let window, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow == window else { return }

        window = nil
        let callback = onClose
        onClose = nil
        callback?()

        closingWindows.append(closingWindow)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak closingWindow] in
            guard let self, let closingWindow else { return }
            closingWindow.delegate = nil
            closingWindow.contentViewController = nil
            self.closingWindows.removeAll { $0 === closingWindow }
        }
    }

    private func defaultFrame(preferredWidth: CGFloat, visibleFrame: CGRect) -> NSRect {
        let savedHeight = UserDefaults.standard.double(forKey: "popoverHeight")
        let maxHeight = max(visibleFrame.height - 30, 260)
        let targetHeight = savedHeight > 0
            ? min(savedHeight + 40, maxHeight)
            : min(560, maxHeight)

        let width = min(preferredWidth, max(visibleFrame.width - 24, preferredWidth))
        let origin = CGPoint(
            x: visibleFrame.midX - (width / 2),
            y: visibleFrame.midY - (targetHeight / 2)
        )
        return NSRect(origin: origin, size: NSSize(width: width, height: targetHeight))
    }

    private func constrainedFrame(_ frame: NSRect, to visibleFrame: CGRect) -> NSRect {
        var constrained = frame

        constrained.size.width = min(constrained.size.width, visibleFrame.width - 12)
        constrained.size.height = min(constrained.size.height, visibleFrame.height - 12)

        if constrained.minX < visibleFrame.minX + 6 {
            constrained.origin.x = visibleFrame.minX + 6
        } else if constrained.maxX > visibleFrame.maxX - 6 {
            constrained.origin.x = visibleFrame.maxX - constrained.width - 6
        }

        if constrained.minY < visibleFrame.minY + 6 {
            constrained.origin.y = visibleFrame.minY + 6
        } else if constrained.maxY > visibleFrame.maxY - 6 {
            constrained.origin.y = visibleFrame.maxY - constrained.height - 6
        }

        return constrained.integral
    }
}
