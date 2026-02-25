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
        let mode = UserDefaults.standard.string(forKey: "menuBarMode") ?? "rates"

        if mode == "icon" {
            stackView.isHidden = true
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            statusItem.button?.image = NSImage(
                systemSymbolName: "network",
                accessibilityDescription: "Network")?.withSymbolConfiguration(cfg)
            statusItem.button?.imagePosition = .imageOnly
            statusItem.length = NSStatusItem.squareLength
            return
        }

        // mode == "rates" — restore and continue as before
        stackView.isHidden = false
        statusItem.button?.image = nil
        statusItem.button?.imagePosition = .noImage

        let useBits = UserDefaults.standard.bool(forKey: "useBits")
        let totals = effectiveTotals()
        let upText = "↑ \(RateFormatter.formatRate(totals.txRateBps, useBits: useBits))"
        let downText = "↓ \(RateFormatter.formatRate(totals.rxRateBps, useBits: useBits))"

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

    private func effectiveTotals() -> RateTotals {
        let onlyVisible = UserDefaults.standard.bool(forKey: "totalsOnlyVisibleAdapters")
        guard onlyVisible else { return monitor.totals }

        let showInactive = UserDefaults.standard.bool(forKey: "showInactive")
        let showOtherAdapters = UserDefaults.standard.bool(forKey: "showOtherAdapters")
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenAdapters") ?? [])

        var rx: Double = 0
        var tx: Double = 0

        for adapter in monitor.adapters {
            if !showOtherAdapters, adapter.type == .other { continue }
            if !showInactive, adapter.rxRateBps == 0, adapter.txRateBps == 0, adapter.isUp == false { continue }
            if hidden.contains(adapter.id) { continue }
            rx += adapter.rxRateBps
            tx += adapter.txRateBps
        }

        return RateTotals(rxRateBps: rx, txRateBps: tx)
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
