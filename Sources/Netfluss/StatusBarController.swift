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

private enum MenuBarDisplayStyle: String {
    case stack = "rates"
    case unified = "unified"
    case dashboard = "dashboard"
}

private struct MenuBarMetrics {
    let rxRateBps: Double
    let txRateBps: Double
    let totalRateBps: Double
    let maxTotalRateBps: Double?
    let historySourceKey: String
}

private struct CompactMetricTexts {
    let down: String
    let up: String
    let total: String
    let reference: String
    let totalReference: String
}

private struct MenuBarDisplayModel {
    let style: MenuBarDisplayStyle
    let font: NSFont
    let smallFont: NSFont
    let emphasisFont: NSFont
    let textColor: NSColor
    let secondaryTextColor: NSColor
    let upColor: NSColor
    let downColor: NSColor
    let upTextColor: NSColor
    let downTextColor: NSColor
    let fillColor: NSColor
    let strokeColor: NSColor
    let ringColor: NSColor
    let fullUpText: String
    let fullDownText: String
    let referenceFullText: String
    let compactUpText: String
    let compactDownText: String
    let referenceCompactText: String
    let totalText: String
    let referenceTotalText: String
    let ringProgress: CGFloat
}

private final class MenuBarRatesView: NSView {
    static let horizontalPadding: CGFloat = 5
    private static let stackSpacing: CGFloat = 1
    private static let capsulePadding: CGFloat = 7

    private struct TextRun {
        let text: String
        let font: NSFont
        let color: NSColor

        var attributes: [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: color]
        }

        var size: NSSize {
            (text as NSString).size(withAttributes: attributes)
        }
    }

    private var model: MenuBarDisplayModel?

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(model: MenuBarDisplayModel) {
        self.model = model
        needsDisplay = true
    }

    static func preferredWidth(for model: MenuBarDisplayModel) -> CGFloat {
        switch model.style {
        case .stack:
            let downRuns = stackRuns(
                text: model.referenceFullText,
                font: model.font,
                textColor: model.downTextColor,
                arrow: "↓",
                arrowColor: model.downColor
            )
            let upRuns = stackRuns(
                text: model.referenceFullText,
                font: model.font,
                textColor: model.upTextColor,
                arrow: "↑",
                arrowColor: model.upColor
            )
            return ceil(max(width(of: downRuns), width(of: upRuns)) + (horizontalPadding * 2))
        case .unified:
            let runs = unifiedRuns(
                downText: model.referenceFullText,
                upText: model.referenceFullText,
                font: model.font,
                downTextColor: model.downTextColor,
                upTextColor: model.upTextColor,
                secondaryTextColor: model.secondaryTextColor,
                downColor: model.downColor,
                upColor: model.upColor
            )
            return ceil(width(of: runs) + (capsulePadding * 2) + (horizontalPadding * 2))
        case .dashboard:
            let runs = dashboardRuns(
                totalText: model.referenceTotalText,
                downText: model.referenceCompactText,
                upText: model.referenceCompactText,
                totalFont: model.emphasisFont,
                detailFont: model.smallFont,
                textColor: model.textColor,
                downTextColor: model.downTextColor,
                upTextColor: model.upTextColor,
                secondaryTextColor: model.secondaryTextColor,
                downColor: model.downColor,
                upColor: model.upColor
            )
            let ringSize = dashboardRingSize(for: model)
            return ceil((horizontalPadding * 3) + ringSize + width(of: runs))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }

        switch model.style {
        case .stack:
            drawStack(model)
        case .unified:
            drawUnified(model)
        case .dashboard:
            drawDashboard(model)
        }
    }

    private func drawStack(_ model: MenuBarDisplayModel) {
        let upRuns = Self.stackRuns(
            text: model.fullUpText,
            font: model.font,
            textColor: model.upTextColor,
            arrow: "↑",
            arrowColor: model.upColor
        )
        let downRuns = Self.stackRuns(
            text: model.fullDownText,
            font: model.font,
            textColor: model.downTextColor,
            arrow: "↓",
            arrowColor: model.downColor
        )

        let lineHeight = Self.lineHeight(for: model.font)
        let totalHeight = (lineHeight * 2) + Self.stackSpacing
        let originY = floor((bounds.height - totalHeight) / 2)

        draw(runs: upRuns, at: NSPoint(x: Self.horizontalPadding, y: originY))
        draw(runs: downRuns, at: NSPoint(x: Self.horizontalPadding, y: originY + lineHeight + Self.stackSpacing))
    }

    private func drawUnified(_ model: MenuBarDisplayModel) {
        let runs = Self.unifiedRuns(
            downText: model.fullDownText,
            upText: model.fullUpText,
            font: model.font,
            downTextColor: model.downTextColor,
            upTextColor: model.upTextColor,
            secondaryTextColor: model.secondaryTextColor,
            downColor: model.downColor,
            upColor: model.upColor
        )
        let lineHeight = Self.lineHeight(for: model.font)
        let capsuleHeight = max(lineHeight + 6, 18)
        let capsuleRect = NSRect(
            x: Self.horizontalPadding,
            y: floor((bounds.height - capsuleHeight) / 2),
            width: bounds.width - (Self.horizontalPadding * 2),
            height: capsuleHeight
        )

        let path = NSBezierPath(roundedRect: capsuleRect, xRadius: capsuleHeight / 2, yRadius: capsuleHeight / 2)
        model.fillColor.setFill()
        path.fill()
        model.strokeColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let textY = floor((bounds.height - lineHeight) / 2)
        let contentWidth = Self.width(of: runs)
        let textX = max(capsuleRect.minX + Self.capsulePadding, floor(capsuleRect.midX - (contentWidth / 2)))
        draw(runs: runs, at: NSPoint(x: textX, y: textY))
    }

    private func drawDashboard(_ model: MenuBarDisplayModel) {
        let runs = Self.dashboardRuns(
            totalText: model.totalText,
            downText: model.compactDownText,
            upText: model.compactUpText,
            totalFont: model.emphasisFont,
            detailFont: model.smallFont,
            textColor: model.textColor,
            downTextColor: model.downTextColor,
            upTextColor: model.upTextColor,
            secondaryTextColor: model.secondaryTextColor,
            downColor: model.downColor,
            upColor: model.upColor
        )
        let capsuleRect = NSRect(
            x: Self.horizontalPadding,
            y: floor((bounds.height - 20) / 2),
            width: bounds.width - (Self.horizontalPadding * 2),
            height: 20
        )

        let path = NSBezierPath(roundedRect: capsuleRect, xRadius: 10, yRadius: 10)
        model.fillColor.setFill()
        path.fill()
        model.strokeColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let ringSize = Self.dashboardRingSize(for: model)
        let ringRect = NSRect(
            x: floor(capsuleRect.midX - ((ringSize + 6 + Self.width(of: runs)) / 2)),
            y: floor((bounds.height - ringSize) / 2),
            width: ringSize,
            height: ringSize
        )
        drawRing(in: ringRect, progress: model.ringProgress, color: model.ringColor, secondaryColor: model.secondaryTextColor)

        let lineHeight = Self.lineHeight(for: model.smallFont)
        let textY = floor((bounds.height - lineHeight) / 2)
        draw(runs: runs, at: NSPoint(x: ringRect.maxX + 6, y: textY))
    }

    @discardableResult
    private func draw(runs: [TextRun], at point: NSPoint) -> CGFloat {
        var x = point.x
        for run in runs {
            (run.text as NSString).draw(at: NSPoint(x: x, y: point.y), withAttributes: run.attributes)
            x += ceil(run.size.width)
        }
        return x - point.x
    }

    private func drawRing(in rect: NSRect, progress: CGFloat, color: NSColor, secondaryColor: NSColor) {
        let background = NSBezierPath(ovalIn: rect)
        secondaryColor.withAlphaComponent(0.25).setStroke()
        background.lineWidth = 2
        background.stroke()

        guard progress > 0 else { return }

        let startAngle: CGFloat = 90
        let endAngle = startAngle - (360 * min(max(progress, 0.08), 1))
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.midY),
            radius: (rect.width / 2) - 1,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        arc.lineWidth = 2.5
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }


    private static func stackRuns(
        text: String,
        font: NSFont,
        textColor: NSColor,
        arrow: String,
        arrowColor: NSColor
    ) -> [TextRun] {
        [
            TextRun(text: arrow, font: font, color: arrowColor),
            TextRun(text: " ", font: font, color: textColor),
            TextRun(text: text, font: font, color: textColor)
        ]
    }

    private static func unifiedRuns(
        downText: String,
        upText: String,
        font: NSFont,
        downTextColor: NSColor,
        upTextColor: NSColor,
        secondaryTextColor: NSColor,
        downColor: NSColor,
        upColor: NSColor
    ) -> [TextRun] {
        [
            TextRun(text: downText, font: font, color: downTextColor),
            TextRun(text: " ", font: font, color: downTextColor),
            TextRun(text: "↓", font: font, color: downColor),
            TextRun(text: " • ", font: font, color: secondaryTextColor),
            TextRun(text: upText, font: font, color: upTextColor),
            TextRun(text: " ", font: font, color: upTextColor),
            TextRun(text: "↑", font: font, color: upColor)
        ]
    }

    private static func dashboardRuns(
        totalText: String,
        downText: String,
        upText: String,
        totalFont: NSFont,
        detailFont: NSFont,
        textColor: NSColor,
        downTextColor: NSColor,
        upTextColor: NSColor,
        secondaryTextColor: NSColor,
        downColor: NSColor,
        upColor: NSColor
    ) -> [TextRun] {
        [
            TextRun(text: "Σ \(totalText)", font: totalFont, color: textColor),
            TextRun(text: "  |  ", font: detailFont, color: secondaryTextColor),
            TextRun(text: "↓", font: detailFont, color: downColor),
            TextRun(text: " \(downText)", font: detailFont, color: downTextColor),
            TextRun(text: "  |  ", font: detailFont, color: secondaryTextColor),
            TextRun(text: "↑", font: detailFont, color: upColor),
            TextRun(text: " \(upText)", font: detailFont, color: upTextColor)
        ]
    }

    private static func width(of runs: [TextRun]) -> CGFloat {
        runs.reduce(0) { $0 + ceil($1.size.width) }
    }

    private static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.boundingRectForFont.height)
    }

    private static func dashboardRingSize(for model: MenuBarDisplayModel) -> CGFloat {
        max(12, lineHeight(for: model.smallFont) + 1)
    }
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private enum PopoverLayout {
        static let preferredWidth: CGFloat = 340
        static let horizontalScreenMargin: CGFloat = 12
        static let anchorScreenInset: CGFloat = 26
    }

    private struct PopoverPresentation {
        let contentWidth: CGFloat
        let sourceRect: NSRect
        let visibleFrame: CGRect
    }

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let monitor: NetworkMonitor
    private var cancellables: Set<AnyCancellable> = []
    private let ratesView = MenuBarRatesView()
    private var cachedFonts: [FontState: NSFont] = [:]
    private var lastRenderState: MenuBarRenderState?
    private var lastStatusItemLength: CGFloat?
    private var currentMenuBarMode: String?
    private var dashboardPeakRateBps: Double = 0
    private var dashboardPeakSourceKey: String?
    private var dashboardPeakDate: Date?

    private struct MenuBarRenderState: Equatable {
        let mode: String
        let upText: String
        let downText: String
        let referenceFullText: String
        let compactUpText: String
        let compactDownText: String
        let referenceCompactText: String
        let totalText: String
        let referenceTotalText: String
        let fontSize: Double
        let fontDesign: String
        let colorKey: String
        let upTextColorKey: String
        let downTextColorKey: String
        let ringProgressBucket: Int
    }

    private struct FontState: Hashable {
        let fontSize: Double
        let fontDesign: String
        let weight: Double
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
        if popover.isShown {
            popover.performClose(nil)
        }
        teardownPopover()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            teardownPopover()
        } else {
            teardownPopover()
            let presentation = popoverPresentation(for: button)
            let contentView = MenuBarView(
                preferredWidth: presentation.contentWidth,
                screenVisibleFrame: presentation.visibleFrame
            )
                .environmentObject(monitor)
            popover.contentViewController = NSHostingController(rootView: contentView)
            monitor.setDetailMonitoringEnabled(true)
            popover.show(relativeTo: presentation.sourceRect, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            DispatchQueue.main.async { [weak self] in
                self?.constrainPopoverToVisibleFrame()
            }
        }
    }

    func popoverWillClose(_ notification: Notification) {
        teardownPopover()
    }

    func popoverDidClose(_ notification: Notification) {
        teardownPopover()
    }

    private func teardownPopover() {
        monitor.setDetailMonitoringEnabled(false)
        if popover.contentViewController != nil {
            popover.contentViewController = nil
        }
    }

    private func popoverPresentation(for button: NSStatusBarButton) -> PopoverPresentation {
        let fallbackVisibleFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        guard let window = button.window else {
            return PopoverPresentation(
                contentWidth: PopoverLayout.preferredWidth,
                sourceRect: button.bounds,
                visibleFrame: fallbackVisibleFrame
            )
        }

        let visibleFrame = window.screen?.visibleFrame ?? fallbackVisibleFrame
        let availableWidth = max(visibleFrame.width - (PopoverLayout.horizontalScreenMargin * 2), 0)
        let contentWidth = availableWidth > 0
            ? min(PopoverLayout.preferredWidth, availableWidth)
            : PopoverLayout.preferredWidth

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = window.convertToScreen(buttonFrameInWindow)
        let clampedAnchorX = min(
            max(buttonFrameOnScreen.midX, visibleFrame.minX + PopoverLayout.anchorScreenInset),
            visibleFrame.maxX - PopoverLayout.anchorScreenInset
        )

        var sourceRect = button.bounds
        sourceRect.origin.x += clampedAnchorX - buttonFrameOnScreen.midX

        return PopoverPresentation(
            contentWidth: contentWidth,
            sourceRect: sourceRect,
            visibleFrame: visibleFrame
        )
    }

    private func constrainPopoverToVisibleFrame() {
        guard
            let window = popover.contentViewController?.view.window,
            let screen = window.screen ?? statusItem.button?.window?.screen
        else { return }

        let visibleFrame = screen.visibleFrame.insetBy(dx: PopoverLayout.horizontalScreenMargin, dy: 0)
        var frame = window.frame

        if frame.minX < visibleFrame.minX {
            frame.origin.x = visibleFrame.minX
        } else if frame.maxX > visibleFrame.maxX {
            frame.origin.x = visibleFrame.maxX - frame.width
        }

        if frame.origin.x != window.frame.origin.x {
            window.setFrame(frame, display: true)
        }
    }

    private func applyPreferences() {
        if UserDefaults.standard.string(forKey: "menuBarMode") == "sparkline" {
            UserDefaults.standard.set("dashboard", forKey: "menuBarMode")
        }

        let interval = UserDefaults.standard.double(forKey: "refreshInterval")
        let effectiveInterval = interval > 0 ? interval : 1.0
        monitor.start(interval: effectiveInterval)

        popover.appearance = nil
        updateLabel()
    }

    private func updateLabel() {
        let mode = normalizedMenuBarMode()

        if mode == "icon" {
            let symbol = normalizedMenuBarIconSymbol()
            let iconState = MenuBarRenderState(
                mode: mode,
                upText: "",
                downText: "",
                referenceFullText: "",
                compactUpText: "",
                compactDownText: "",
                referenceCompactText: "",
                totalText: "",
                referenceTotalText: "",
                fontSize: 0,
                fontDesign: "",
                colorKey: symbol,
                upTextColorKey: "",
                downTextColorKey: "",
                ringProgressBucket: 0
            )
            if lastRenderState == iconState { return }
            lastRenderState = iconState
            if currentMenuBarMode != mode {
                ratesView.isHidden = true
                currentMenuBarMode = mode
            }
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            statusItem.button?.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: "Network"
            )?.withSymbolConfiguration(cfg)
            statusItem.button?.imagePosition = .imageOnly
            if lastStatusItemLength != NSStatusItem.squareLength {
                statusItem.length = NSStatusItem.squareLength
                lastStatusItemLength = NSStatusItem.squareLength
            }
            return
        }

        guard
            let button = statusItem.button,
            let style = MenuBarDisplayStyle(rawValue: mode)
        else { return }

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

        let effectiveDecimals: Int
        if rawDecimals == 0 {
            effectiveDecimals = pinnedUnit == "auto" ? -1 : 2
        } else if rawDecimals == 10 {
            effectiveDecimals = 0
        } else {
            effectiveDecimals = rawDecimals
        }

        let metrics = metrics(for: style)
        let fullUpText = formatRate(metrics.txRateBps, useBits: useBits, pinnedUnit: pinnedUnit, decimals: effectiveDecimals)
        let fullDownText = formatRate(metrics.rxRateBps, useBits: useBits, pinnedUnit: pinnedUnit, decimals: effectiveDecimals)
        let referenceFullText = fullRateReferenceText(useBits: useBits, pinnedUnit: pinnedUnit, decimals: effectiveDecimals)

        let compactTexts = compactMetricTexts(
            for: metrics,
            useBits: useBits,
            pinnedUnit: pinnedUnit,
            decimals: effectiveDecimals
        )
        let ringProgress = style == .dashboard
            ? ringProgress(for: metrics)
            : 0

        let theme = AppTheme.system
        let uploadColorName = UserDefaults.standard.string(forKey: "uploadColor") ?? "green"
        let downloadColorName = UserDefaults.standard.string(forKey: "downloadColor") ?? "blue"
        let uploadColorHex = UserDefaults.standard.string(forKey: "uploadColorHex") ?? ""
        let downloadColorHex = UserDefaults.standard.string(forKey: "downloadColorHex") ?? ""
        let menuBarUploadTextColorName = UserDefaults.standard.string(forKey: "menuBarUploadTextColor") ?? "green"
        let menuBarDownloadTextColorName = UserDefaults.standard.string(forKey: "menuBarDownloadTextColor") ?? "blue"
        let menuBarUploadTextColorHex = UserDefaults.standard.string(forKey: "menuBarUploadTextColorHex") ?? ""
        let menuBarDownloadTextColorHex = UserDefaults.standard.string(forKey: "menuBarDownloadTextColorHex") ?? ""
        let upColor = resolvedAccentNSColor(
            selection: uploadColorName,
            customHex: uploadColorHex,
            fallback: NSColor(theme.uploadColor)
        )
        let downColor = resolvedAccentNSColor(
            selection: downloadColorName,
            customHex: downloadColorHex,
            fallback: NSColor(theme.downloadColor)
        )
        let upTextColor = resolvedAccentNSColor(
            selection: menuBarUploadTextColorName,
            customHex: menuBarUploadTextColorHex,
            fallback: upColor
        )
        let downTextColor = resolvedAccentNSColor(
            selection: menuBarDownloadTextColorName,
            customHex: menuBarDownloadTextColorHex,
            fallback: downColor
        )

        let defaultTextColor: NSColor
        switch style {
        case .dashboard:
            defaultTextColor = .white
        case .stack, .unified:
            defaultTextColor = .labelColor
        }
        let textColor = defaultTextColor
        let secondaryTextColor: NSColor = {
            switch style {
            case .dashboard:
                return .white.withAlphaComponent(0.68)
            case .stack, .unified:
                return .secondaryLabelColor
            }
        }()

        let isDarkAppearance = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fillColor: NSColor = {
            switch style {
            case .stack:
                return .clear
            case .unified:
                return isDarkAppearance
                    ? NSColor(calibratedWhite: 1, alpha: 0.14)
                    : NSColor(calibratedWhite: 0, alpha: 0.10)
            case .dashboard:
                return NSColor(calibratedWhite: 0, alpha: 0.78)
            }
        }()
        let strokeColor: NSColor = {
            switch style {
            case .stack:
                return .clear
            case .dashboard:
                return NSColor.white.withAlphaComponent(0.10)
            case .unified:
                return isDarkAppearance
                    ? NSColor.white.withAlphaComponent(0.10)
                    : NSColor.black.withAlphaComponent(0.10)
            }
        }()

        let totalRate = max(metrics.totalRateBps, 0.0)
        let ringBlend = totalRate > 0 ? CGFloat(metrics.txRateBps / totalRate) : 0.5
        let ringColor = downColor.blended(withFraction: ringBlend, of: upColor) ?? downColor

        let colorKey = [
            uploadColorName,
            downloadColorName,
            uploadColorHex,
            downloadColorHex
        ].joined(separator: ":")
        let renderState = MenuBarRenderState(
            mode: mode,
            upText: fullUpText,
            downText: fullDownText,
            referenceFullText: referenceFullText,
            compactUpText: compactTexts.up,
            compactDownText: compactTexts.down,
            referenceCompactText: compactTexts.reference,
            totalText: compactTexts.total,
            referenceTotalText: compactTexts.totalReference,
            fontSize: fontSize,
            fontDesign: fontDesign,
            colorKey: colorKey,
            upTextColorKey: [menuBarUploadTextColorName, menuBarUploadTextColorHex].joined(separator: ":"),
            downTextColorKey: [menuBarDownloadTextColorName, menuBarDownloadTextColorHex].joined(separator: ":"),
            ringProgressBucket: Int((ringProgress * 100).rounded())
        )
        if lastRenderState == renderState { return }
        lastRenderState = renderState

        let font = menuBarFont(size: fontSize, design: fontDesign, weight: .medium)
        let smallFont = menuBarFont(size: max(8, fontSize - 1), design: fontDesign, weight: .medium)
        let emphasisFont = menuBarFont(size: min(18, fontSize + 1), design: fontDesign, weight: .semibold)
        let model = MenuBarDisplayModel(
            style: style,
            font: font,
            smallFont: smallFont,
            emphasisFont: emphasisFont,
            textColor: textColor,
            secondaryTextColor: secondaryTextColor,
            upColor: upColor,
            downColor: downColor,
            upTextColor: upTextColor,
            downTextColor: downTextColor,
            fillColor: fillColor,
            strokeColor: strokeColor,
            ringColor: ringColor,
            fullUpText: fullUpText,
            fullDownText: fullDownText,
            referenceFullText: referenceFullText,
            compactUpText: compactTexts.up,
            compactDownText: compactTexts.down,
            referenceCompactText: compactTexts.reference,
            totalText: compactTexts.total,
            referenceTotalText: compactTexts.totalReference,
            ringProgress: ringProgress
        )

        let targetLength = MenuBarRatesView.preferredWidth(for: model)
        if lastStatusItemLength != targetLength {
            statusItem.length = targetLength
            lastStatusItemLength = targetLength
        }

        ratesView.update(model: model)
        layoutRatesView(in: button)
    }

    private func menuBarFont(size: Double, design: String, weight: NSFont.Weight) -> NSFont {
        let state = FontState(fontSize: size, fontDesign: design, weight: Double(weight.rawValue))
        if let cached = cachedFonts[state] {
            return cached
        }

        let font: NSFont
        switch design {
        case "monospaced":
            font = .monospacedSystemFont(ofSize: size, weight: weight)
        case "rounded":
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
            font = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
        default:
            font = .systemFont(ofSize: size, weight: weight)
        }

        cachedFonts[state] = font
        return font
    }

    private func metrics(for style: MenuBarDisplayStyle) -> MenuBarMetrics {
        switch style {
        case .dashboard:
            return routerAwareMetrics() ?? localMetrics()
        case .stack, .unified:
            return localMetrics()
        }
    }

    private func localMetrics() -> MenuBarMetrics {
        let totals = effectiveTotals()
        return MenuBarMetrics(
            rxRateBps: totals.rxRateBps,
            txRateBps: totals.txRateBps,
            totalRateBps: totals.rxRateBps + totals.txRateBps,
            maxTotalRateBps: nil,
            historySourceKey: "local"
        )
    }

    private func routerAwareMetrics() -> MenuBarMetrics? {
        if UserDefaults.standard.bool(forKey: "fritzBoxEnabled"), let data = monitor.fritzBox {
            let maxTotal = (monitor.fritzBoxMaxDown > 0 || monitor.fritzBoxMaxUp > 0)
                ? Double(monitor.fritzBoxMaxDown + monitor.fritzBoxMaxUp) / 8.0
                : nil
            return MenuBarMetrics(
                rxRateBps: data.rxRateBps,
                txRateBps: data.txRateBps,
                totalRateBps: data.rxRateBps + data.txRateBps,
                maxTotalRateBps: maxTotal,
                historySourceKey: "router:fritzbox"
            )
        }

        if UserDefaults.standard.bool(forKey: "unifiEnabled"), let data = monitor.unifi {
            let maxTotal = (data.maxDownstreamMbps > 0 || data.maxUpstreamMbps > 0)
                ? Double(data.maxDownstreamMbps + data.maxUpstreamMbps) * 125_000.0
                : nil
            return MenuBarMetrics(
                rxRateBps: data.rxRateBps,
                txRateBps: data.txRateBps,
                totalRateBps: data.rxRateBps + data.txRateBps,
                maxTotalRateBps: maxTotal,
                historySourceKey: "router:unifi"
            )
        }

        if UserDefaults.standard.bool(forKey: "openWRTEnabled"), let data = monitor.openWRT {
            let maxTotal = data.linkSpeedMbps > 0 ? Double(data.linkSpeedMbps) * 250_000.0 : nil
            return MenuBarMetrics(
                rxRateBps: data.rxRateBps,
                txRateBps: data.txRateBps,
                totalRateBps: data.rxRateBps + data.txRateBps,
                maxTotalRateBps: maxTotal,
                historySourceKey: "router:openwrt"
            )
        }

        return nil
    }

    private func compactMetricTexts(
        for metrics: MenuBarMetrics,
        useBits: Bool,
        pinnedUnit: String,
        decimals: Int
    ) -> CompactMetricTexts {
        let referenceValue = max(metrics.totalRateBps, max(metrics.rxRateBps, metrics.txRateBps))
        let scaleIndex = compactScaleIndex(for: referenceValue, useBits: useBits, pinnedUnit: pinnedUnit)

        return CompactMetricTexts(
            down: compactRateText(metrics.rxRateBps, useBits: useBits, scaleIndex: scaleIndex, decimals: decimals),
            up: compactRateText(metrics.txRateBps, useBits: useBits, scaleIndex: scaleIndex, decimals: decimals),
            total: compactRateText(metrics.totalRateBps, useBits: useBits, scaleIndex: scaleIndex, decimals: decimals),
            reference: compactReferenceText(decimals: decimals, total: false),
            totalReference: compactReferenceText(decimals: decimals, total: true)
        )
    }

    private func compactScaleIndex(for bytesPerSecond: Double, useBits: Bool, pinnedUnit: String) -> Int {
        if pinnedUnit != "auto" {
            switch pinnedUnit {
            case "K": return 1
            case "M": return 2
            case "G": return 3
            default: return 0
            }
        }

        var adjusted = max(0, useBits ? bytesPerSecond * 8.0 : bytesPerSecond)
        var unitIndex = 0
        while adjusted >= 1000.0 && unitIndex < 4 {
            adjusted /= 1000.0
            unitIndex += 1
        }
        return unitIndex
    }

    private func compactRateText(
        _ bytesPerSecond: Double,
        useBits: Bool,
        scaleIndex: Int,
        decimals: Int
    ) -> String {
        let base = max(0, useBits ? bytesPerSecond * 8.0 : bytesPerSecond)
        let scaled = base / pow(1000.0, Double(scaleIndex))
        let effectiveDecimals = compactDecimals(for: scaled, preference: decimals)
        return String(format: "%.\(effectiveDecimals)f", scaled)
    }

    private func compactReferenceText(decimals: Int, total: Bool) -> String {
        let effectiveDecimals = decimals >= 0 ? decimals : 1
        let integerPart = total ? "1999" : "999"
        let decimalPart = effectiveDecimals > 0 ? ".\(String(repeating: "9", count: effectiveDecimals))" : ""
        return integerPart + decimalPart
    }

    private func compactDecimals(for scaledValue: Double, preference: Int) -> Int {
        if preference >= 0 { return preference }
        return scaledValue >= 100 ? 0 : 1
    }

    private func formatRate(_ bytesPerSecond: Double, useBits: Bool, pinnedUnit: String, decimals: Int) -> String {
        if decimals >= 0 {
            return RateFormatter.formatRate(bytesPerSecond, useBits: useBits, pinnedUnit: pinnedUnit, decimals: decimals)
        }
        return RateFormatter.formatRate(bytesPerSecond, useBits: useBits)
    }

    private func fullRateReferenceText(useBits: Bool, pinnedUnit: String, decimals: Int) -> String {
        if pinnedUnit != "auto" {
            let effectiveDecimals = max(0, decimals)
            let decimalPart = effectiveDecimals > 0 ? ".\(String(repeating: "9", count: effectiveDecimals))" : ""
            let unitSuffix: String
            switch pinnedUnit {
            case "K": unitSuffix = useBits ? "Kb/s" : "KB/s"
            case "G": unitSuffix = useBits ? "Gb/s" : "GB/s"
            default: unitSuffix = useBits ? "Mb/s" : "MB/s"
            }
            return "999\(decimalPart) \(unitSuffix)"
        }
        return useBits ? "9.99 Mb/s" : "9.99 MB/s"
    }

    private func ringProgress(for metrics: MenuBarMetrics) -> CGFloat {
        if let reference = metrics.maxTotalRateBps, reference > 0 {
            let ratio = CGFloat(metrics.totalRateBps / reference)
            if ratio <= 0 { return 0 }
            return min(max(ratio, 0.08), 1)
        }

        let now = Date()
        if dashboardPeakSourceKey != metrics.historySourceKey {
            dashboardPeakSourceKey = metrics.historySourceKey
            dashboardPeakRateBps = max(metrics.totalRateBps, 1)
            dashboardPeakDate = now
        } else if let last = dashboardPeakDate {
            let elapsed = max(now.timeIntervalSince(last), 0)
            let decayFactor = pow(0.92, elapsed)
            dashboardPeakRateBps = max(max(metrics.totalRateBps, dashboardPeakRateBps * decayFactor), 1)
            dashboardPeakDate = now
        } else {
            dashboardPeakRateBps = max(max(metrics.totalRateBps, dashboardPeakRateBps), 1)
            dashboardPeakDate = now
        }

        let ratio = CGFloat(metrics.totalRateBps / max(dashboardPeakRateBps, 1))
        if ratio <= 0 { return 0 }
        return min(max(ratio, 0.08), 1)
    }

    private func normalizedMenuBarMode() -> String {
        let mode = UserDefaults.standard.string(forKey: "menuBarMode") ?? "rates"
        if mode == "sparkline" {
            UserDefaults.standard.set("dashboard", forKey: "menuBarMode")
            return "dashboard"
        }
        return mode
    }

    private func normalizedMenuBarIconSymbol() -> String {
        let symbol = UserDefaults.standard.string(forKey: "menuBarIconSymbol") ?? "network"
        switch symbol {
        case "network", "arrow.up.arrow.down", "wifi", "antenna.radiowaves.left.and.right":
            return symbol
        default:
            UserDefaults.standard.set("network", forKey: "menuBarIconSymbol")
            return "network"
        }
    }

    private func effectiveTotals() -> RateTotals {
        let onlyVisible = UserDefaults.standard.bool(forKey: "totalsOnlyVisibleAdapters")
        let excludeTunnelAdapters = UserDefaults.standard.bool(forKey: "excludeTunnelAdaptersFromTotals")
        guard onlyVisible || excludeTunnelAdapters else { return monitor.totals }

        let showInactive = UserDefaults.standard.bool(forKey: "showInactive")
        let showOtherAdapters = UserDefaults.standard.bool(forKey: "showOtherAdapters")
        let graceEnabled = UserDefaults.standard.bool(forKey: "adapterGracePeriodEnabled")
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenAdapters") ?? [])

        return AdapterTotalsFilter.totals(
            from: monitor.adapters,
            onlyVisible: onlyVisible,
            excludeTunnelAdapters: excludeTunnelAdapters,
            showOtherAdapters: showOtherAdapters,
            showInactive: showInactive,
            graceEnabled: graceEnabled,
            hidden: hidden,
            graceDeadlines: monitor.adapterGraceDeadlines
        )
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
