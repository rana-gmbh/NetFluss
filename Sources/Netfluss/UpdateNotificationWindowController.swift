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
final class UpdateNotificationWindowController: NSObject, NSWindowDelegate {
    static let shared = UpdateNotificationWindowController()

    private var window: NSWindow?
    private var closingWindows: [NSWindow] = []

    func show(update: AvailableUpdate) {
        if let window, window.isVisible {
            if let hosting = window.contentViewController as? NSHostingController<UpdateNotificationView> {
                hosting.rootView = UpdateNotificationView(update: update) {
                    NSWorkspace.shared.open(update.releasePageURL)
                    window.close()
                } onLater: {
                    window.close()
                }
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = UpdateNotificationView(update: update) { [weak self] in
            NSWorkspace.shared.open(update.releasePageURL)
            self?.window?.close()
        } onLater: { [weak self] in
            self?.window?.close()
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Update Available"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.level = .floating
        window.setContentSize(NSSize(width: 360, height: 180))
        window.center()
        window.delegate = self
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

private struct UpdateNotificationView: View {
    let update: AvailableUpdate
    let onOpenReleasePage: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Netfluss \(update.version) is available")
                        .font(.headline)
                    Text("A newer version is available on GitHub. Open the latest release page to download it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Later", action: onLater)
                    .keyboardShortcut(.cancelAction)
                Button("Open Release Page", action: onOpenReleasePage)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360, height: 180)
    }
}
