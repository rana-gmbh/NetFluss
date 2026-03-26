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

extension Notification.Name {
    static let closePopover = Notification.Name("com.local.netfluss.closePopover")
}

@MainActor
final class StatusBarController: NSObject {
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

        NotificationCenter.default.addObserver(
            self, selector: #selector(closePopover),
            name: .closePopover, object: nil
        )

        applyPreferences()
        updateLabel()
    }

    @objc private func closePopover() {
        popover.performClose(nil)
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
        let pinnedUnit = UserDefaults.standard.string(forKey: "menuBarPinnedUnit") ?? "auto"
        let rawDecimals = UserDefaults.standard.integer(forKey: "menuBarDecimals")
        // 0 = auto, 10 = 0 decimals, 1/2/3 = that many decimals
        let effectiveDecimals: Int
        if rawDecimals == 0 {
            effectiveDecimals = pinnedUnit == "auto" ? -1 : 2  // auto: use default formatting; pinned: default to 2
        } else if rawDecimals == 10 {
            effectiveDecimals = 0
        } else {
            effectiveDecimals = rawDecimals
        }

        let totals = effectiveTotals()
        let upFormatted: String
        let downFormatted: String
        if effectiveDecimals >= 0 {
            upFormatted = RateFormatter.formatRate(totals.txRateBps, useBits: useBits, pinnedUnit: pinnedUnit, decimals: effectiveDecimals)
            downFormatted = RateFormatter.formatRate(totals.rxRateBps, useBits: useBits, pinnedUnit: pinnedUnit, decimals: effectiveDecimals)
        } else {
            upFormatted = RateFormatter.formatRate(totals.txRateBps, useBits: useBits)
            downFormatted = RateFormatter.formatRate(totals.rxRateBps, useBits: useBits)
        }
        let upText = "↑ \(upFormatted)"
        let downText = "↓ \(downFormatted)"

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

        stackView.alignment = .leading

        // Fixed width: measure a reference string so the menu bar never shifts
        // when values cross unit boundaries (e.g. 999 KB/s → 1.2 MB/s).
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let refText: String
        if pinnedUnit != "auto" {
            let dec = max(0, effectiveDecimals)
            let decPart = dec > 0 ? ".\(String(repeating: "9", count: dec))" : ""
            let unitSuffix: String
            switch pinnedUnit {
            case "K": unitSuffix = useBits ? "Kb/s" : "KB/s"
            case "G": unitSuffix = useBits ? "Gb/s" : "GB/s"
            default:  unitSuffix = useBits ? "Mb/s" : "MB/s"
            }
            refText = "↓ 999\(decPart) \(unitSuffix)"
        } else {
            refText = useBits ? "↓ 9.99 Mb/s" : "↓ 9.99 MB/s"
        }
        let refW = (refText as NSString).size(withAttributes: attrs).width
        statusItem.length = ceil(refW) + 4  // 2 px padding each side
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
        case "black":  return .black
        default:       return fallback
        }
    }

    private func effectiveTotals() -> RateTotals {
        let onlyVisible = UserDefaults.standard.bool(forKey: "totalsOnlyVisibleAdapters")
        guard onlyVisible else { return monitor.totals }

        let showInactive = UserDefaults.standard.bool(forKey: "showInactive")
        let showOtherAdapters = UserDefaults.standard.bool(forKey: "showOtherAdapters")
        let graceEnabled = UserDefaults.standard.bool(forKey: "adapterGracePeriodEnabled")
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenAdapters") ?? [])

        var rx: Double = 0
        var tx: Double = 0

        for adapter in monitor.adapters {
            if !showOtherAdapters, adapter.type == .other { continue }
            if hidden.contains(adapter.id) { continue }
            let zeroBandwidth = adapter.rxRateBps == 0 && adapter.txRateBps == 0
            if graceEnabled, zeroBandwidth {
                if monitor.adapterGraceDeadlines[adapter.id] == nil { continue }
            } else if !showInactive, zeroBandwidth, !adapter.isUp {
                continue
            }
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
            stackView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2)
        ])
    }
}
