import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSObject {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: AboutView())
        hosting.sizingOptions = .preferredContentSize

        let window = NSWindow(contentViewController: hosting)
        window.title = "About Netfluss"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )

        self.window = window
    }

    @objc private func windowWillClose() {
        window = nil
    }
}
