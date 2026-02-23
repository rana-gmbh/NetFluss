import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, ObservableObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let monitor: NetworkMonitor
    private var cancellables: Set<AnyCancellable> = []
    private let upLabel = NSTextField(labelWithString: "")
    private let downLabel = NSTextField(labelWithString: "")
    private let stackView = NSStackView()

    init(monitor: NetworkMonitor) {
        self.monitor = monitor
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.setButtonType(.momentaryChange)
            configureLabels(in: button)
        }

        let contentView = MenuBarView()
            .environmentObject(monitor)
            .frame(width: 340)
        popover.contentViewController = NSHostingController(rootView: contentView)
        popover.behavior = .transient

        monitor.$totals
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLabel()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyPreferences()
            }
            .store(in: &cancellables)

        applyPreferences()
        updateLabel()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func applyPreferences() {
        let interval = UserDefaults.standard.double(forKey: "refreshInterval")
        let effectiveInterval = interval > 0 ? interval : 1.0
        monitor.start(interval: effectiveInterval)

        let theme = AppTheme.named(UserDefaults.standard.string(forKey: "theme") ?? "system")
        popover.appearance = theme.isDark ? NSAppearance(named: .darkAqua) : nil

        updateLabel()
    }

    private func updateLabel() {
        let useBits = UserDefaults.standard.bool(forKey: "useBits")
        let upText = "↑ \(RateFormatter.formatRate(monitor.totals.txRateBps, useBits: useBits))"
        let downText = "↓ \(RateFormatter.formatRate(monitor.totals.rxRateBps, useBits: useBits))"

        upLabel.stringValue = upText
        downLabel.stringValue = downText

        let font = menuBarFont()
        upLabel.font = font
        downLabel.font = font

        let theme = AppTheme.named(UserDefaults.standard.string(forKey: "theme") ?? "system")
        if theme.id == "system" {
            upLabel.textColor  = nsColor(for: UserDefaults.standard.string(forKey: "uploadColor")   ?? "green", default: .systemGreen)
            downLabel.textColor = nsColor(for: UserDefaults.standard.string(forKey: "downloadColor") ?? "blue",  default: .systemBlue)
        } else {
            upLabel.textColor   = NSColor(theme.uploadColor)
            downLabel.textColor = NSColor(theme.downloadColor)
        }

        // Keep the status item width snug to the content so the gap to the
        // next menu bar icon stays consistent regardless of font size.
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let upW   = (upText   as NSString).size(withAttributes: attrs).width
        let downW = (downText as NSString).size(withAttributes: attrs).width
        statusItem.length = ceil(max(upW, downW)) + 4  // 2 px padding each side
    }

    private func menuBarFont() -> NSFont {
        let raw = UserDefaults.standard.double(forKey: "menuBarFontSize")
        let size = max(8, min(16, raw > 0 ? raw : 10))
        switch UserDefaults.standard.string(forKey: "menuBarFontDesign") ?? "monospaced" {
        case "monospaced":
            return .monospacedSystemFont(ofSize: size, weight: .medium)
        case "rounded":
            let base = NSFont.systemFont(ofSize: size, weight: .medium)
            let desc = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
            return NSFont(descriptor: desc, size: size) ?? .systemFont(ofSize: size, weight: .medium)
        default:
            return .systemFont(ofSize: size, weight: .medium)
        }
    }

    private func nsColor(for name: String, default fallback: NSColor) -> NSColor {
        switch name {
        case "green":  return .systemGreen
        case "blue":   return .systemBlue
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "teal":   return .systemTeal
        case "purple": return .systemPurple
        case "pink":   return .systemPink
        case "white":  return .white
        default:       return fallback
        }
    }

    private func configureLabels(in button: NSStatusBarButton) {
        stackView.orientation = .vertical
        stackView.spacing = 1
        stackView.alignment = .leading
        stackView.addArrangedSubview(upLabel)
        stackView.addArrangedSubview(downLabel)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        button.title = ""
        button.image = nil
        button.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            stackView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 2)
        ])
    }
}
