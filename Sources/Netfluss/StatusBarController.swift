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

private final class MenuBarRatesView: NSView {
    static let horizontalPadding: CGFloat = 2
    private static let verticalSpacing: CGFloat = 1

    private var upText = NSAttributedString(string: "")
    private var downText = NSAttributedString(string: "")
    private var contentWidth: CGFloat = 0
    private var lineHeight: CGFloat = 0

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(
        upText: NSAttributedString,
        downText: NSAttributedString,
        contentWidth: CGFloat,
        lineHeight: CGFloat
    ) {
        self.upText = upText
        self.downText = downText
        self.contentWidth = contentWidth
        self.lineHeight = lineHeight
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard contentWidth > 0, lineHeight > 0 else { return }

        let totalHeight = (lineHeight * 2) + Self.verticalSpacing
        let originY = floor((bounds.height - totalHeight) / 2)
        let drawWidth = contentWidth

        upText.draw(in: NSRect(
            x: Self.horizontalPadding,
            y: originY,
            width: drawWidth,
            height: lineHeight
        ))
        downText.draw(in: NSRect(
            x: Self.horizontalPadding,
            y: originY + lineHeight + Self.verticalSpacing,
            width: drawWidth,
            height: lineHeight
        ))
    }
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let monitor: NetworkMonitor
    private var cancellables: Set<AnyCancellable> = []
    private let ratesView = MenuBarRatesView()
    // Cached font to avoid recreating on every tick
    private var cachedFont: NSFont?
    private var cachedFontSize: Double = 0
    private var cachedFontDesign: String = ""
    private var lastRenderState: MenuBarRenderState?
    private var lastStatusItemLength: CGFloat?
    private var currentMenuBarMode: String?
    private var cachedReferenceWidthState: ReferenceWidthState?
    private var cachedReferenceWidth: CGFloat = 0
    private var cachedLineHeightState: FontState?
    private var cachedLineHeight: CGFloat = 0

    private struct MenuBarRenderState: Equatable {
        let mode: String
        let upText: String
        let downText: String
        let refText: String
        let fontSize: Double
        let fontDesign: String
        let colorKey: String
    }

    private struct FontState: Equatable {
        let fontSize: Double
        let fontDesign: String
    }

    private struct ReferenceWidthState: Equatable {
        let refText: String
        let font: FontState
    }

    init(monitor: NetworkMonitor) {
        self.monitor = monitor
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.setButtonType(.momentaryChange)
            configureRatesView(in: button)
        }

        popover.behavior = .transient
        popover.delegate = self

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
            if popover.contentViewController == nil {
                let contentView = MenuBarView()
                    .environmentObject(monitor)
                    .frame(width: 340)
                popover.contentViewController = NSHostingController(rootView: contentView)
            }
            monitor.setDetailMonitoringEnabled(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.setDetailMonitoringEnabled(false)
        popover.contentViewController = nil
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
            let iconState = MenuBarRenderState(
                mode: mode,
                upText: "",
                downText: "",
                refText: "",
                fontSize: 0,
                fontDesign: "",
                colorKey: ""
            )
            if lastRenderState == iconState { return }
            lastRenderState = iconState
            if currentMenuBarMode != mode {
                ratesView.isHidden = true
                let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                statusItem.button?.image = NSImage(
                    systemSymbolName: "network",
                    accessibilityDescription: "Network")?.withSymbolConfiguration(cfg)
                statusItem.button?.imagePosition = .imageOnly
                currentMenuBarMode = mode
            }
            if lastStatusItemLength != NSStatusItem.squareLength {
                statusItem.length = NSStatusItem.squareLength
                lastStatusItemLength = NSStatusItem.squareLength
            }
            return
        }

        // mode == "rates" — restore and continue as before
        guard let button = statusItem.button else { return }
        if currentMenuBarMode != mode {
            ratesView.isHidden = false
            button.image = nil
            button.imagePosition = .noImage
            currentMenuBarMode = mode
        }

        let useBits = UserDefaults.standard.bool(forKey: "useBits")
        let pinnedUnit = UserDefaults.standard.string(forKey: "menuBarPinnedUnit") ?? "auto"
        let rawDecimals = UserDefaults.standard.integer(forKey: "menuBarDecimals")
        let rawFontSize = UserDefaults.standard.double(forKey: "menuBarFontSize")
        let fontSize = max(8, min(16, rawFontSize > 0 ? rawFontSize : 10))
        let fontDesign = UserDefaults.standard.string(forKey: "menuBarFontDesign") ?? "monospaced"
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

        let theme = AppTheme.named(UserDefaults.standard.string(forKey: "theme") ?? "system")
        let upColor: NSColor
        let downColor: NSColor
        let colorKey: String
        if theme.id == "system" {
            let uploadColor = UserDefaults.standard.string(forKey: "uploadColor") ?? "green"
            let downloadColor = UserDefaults.standard.string(forKey: "downloadColor") ?? "blue"
            upColor  = nsColor(for: uploadColor, default: .systemGreen)
            downColor = nsColor(for: downloadColor, default: .systemBlue)
            colorKey = "system:\(uploadColor):\(downloadColor)"
        } else {
            upColor   = NSColor(theme.uploadColor)
            downColor = NSColor(theme.downloadColor)
            colorKey = theme.id
        }

        // Fixed width: measure a reference string so the menu bar never shifts
        // when values cross unit boundaries (e.g. 999 KB/s → 1.2 MB/s).
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

        let upText = "↑ \(upFormatted)"
        let downText = "↓ \(downFormatted)"
        let renderState = MenuBarRenderState(
            mode: mode,
            upText: upText,
            downText: downText,
            refText: refText,
            fontSize: fontSize,
            fontDesign: fontDesign,
            colorKey: colorKey
        )
        if lastRenderState == renderState { return }
        lastRenderState = renderState

        let font = menuBarFont(size: fontSize, design: fontDesign)
        let fontState = FontState(fontSize: fontSize, fontDesign: fontDesign)
        let refW = referenceWidth(for: refText, font: font, state: fontState)
        let targetLength = refW + (MenuBarRatesView.horizontalPadding * 2)
        if lastStatusItemLength != targetLength {
            statusItem.length = targetLength
            lastStatusItemLength = targetLength
        }

        let upAttributedText = NSAttributedString(string: upText, attributes: [
            .font: font,
            .foregroundColor: upColor
        ])
        let downAttributedText = NSAttributedString(string: downText, attributes: [
            .font: font, .foregroundColor: downColor
        ])
        ratesView.update(
            upText: upAttributedText,
            downText: downAttributedText,
            contentWidth: refW,
            lineHeight: lineHeight(for: font, state: fontState)
        )
        layoutRatesView(in: button)
    }

    private func menuBarFont(size: Double, design: String) -> NSFont {
        // Return cached font if settings haven't changed
        if let cached = cachedFont, cachedFontSize == size, cachedFontDesign == design {
            return cached
        }
        let font: NSFont
        switch design {
        case "monospaced":
            font = .monospacedSystemFont(ofSize: size, weight: .medium)
        case "rounded":
            let base = NSFont.systemFont(ofSize: size, weight: .medium)
            let desc = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
            font = NSFont(descriptor: desc, size: size) ?? .systemFont(ofSize: size, weight: .medium)
        default:
            font = .systemFont(ofSize: size, weight: .medium)
        }
        cachedFont = font
        cachedFontSize = size
        cachedFontDesign = design
        return font
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

    private func referenceWidth(for text: String, font: NSFont, state: FontState) -> CGFloat {
        let referenceState = ReferenceWidthState(refText: text, font: state)
        if cachedReferenceWidthState == referenceState {
            return cachedReferenceWidth
        }

        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        cachedReferenceWidthState = referenceState
        cachedReferenceWidth = width
        return width
    }

    private func lineHeight(for font: NSFont, state: FontState) -> CGFloat {
        if cachedLineHeightState == state {
            return cachedLineHeight
        }

        let height = ceil(font.boundingRectForFont.height)
        cachedLineHeightState = state
        cachedLineHeight = height
        return height
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

    private func configureRatesView(in button: NSStatusBarButton) {
        button.title = ""
        button.image = nil
        ratesView.frame = button.bounds
        ratesView.autoresizingMask = [.width, .height]
        button.addSubview(ratesView)
    }

    private func layoutRatesView(in button: NSStatusBarButton) {
        if ratesView.superview !== button {
            button.addSubview(ratesView)
        }
        if ratesView.frame != button.bounds {
            ratesView.frame = button.bounds
        }
    }
}
