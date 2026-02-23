import AppKit
import SwiftUI

@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

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
        win.setContentSize(NSSize(width: 300, height: 420))
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        self.window = win
    }
}
