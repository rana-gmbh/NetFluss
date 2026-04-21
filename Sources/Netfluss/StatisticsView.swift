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

import Charts
import SwiftUI

private let statisticsRangePickerWidth: CGFloat = 336
private let statisticsRangeControlHeight: CGFloat = 32
private let statisticsRangeControlsGap: CGFloat = 6
private let statisticsRangeLabelColumnWidth: CGFloat = 62

struct StatisticsView: View {
    @EnvironmentObject private var statisticsManager: StatisticsManager
    @EnvironmentObject private var monitor: NetworkMonitor
    @AppStorage("collectStatistics") private var collectStatistics: Bool = false
    @AppStorage("collectAppStatistics") private var collectAppStatistics: Bool = true

    @State private var range: StatisticsRange = .last24Hours
    @State private var customRangeActive = false
    @State private var customStart: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEnd: Date = Date()
    @State private var customDraftStart: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customDraftEnd: Date = Date()
    @State private var showingCustomRangePopover = false
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .decimal
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(AppTheme.system.backgroundColor ?? Color(NSColor.windowBackgroundColor))
        .frame(minWidth: 860, minHeight: 620)
        .onAppear {
            loadSelectedReport()
        }
        .onChange(of: range) { newValue in
            customRangeActive = false
            statisticsManager.loadReport(for: newValue)
        }
        .onChange(of: collectStatistics) { _ in
            statisticsManager.refreshCurrentReport()
        }
        .onChange(of: collectAppStatistics) { _ in
            statisticsManager.refreshCurrentReport()
        }
        .onReceive(refreshTimer) { _ in
            statisticsManager.refreshCurrentReport()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    LText("Statistics")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(localizedHeaderSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 12) {
                    if statisticsManager.sampleDataControlsEnabled {
                        Button {
                            if statisticsManager.isShowingSampleData {
                                statisticsManager.disableSampleData()
                            } else {
                                statisticsManager.enableSampleData()
                            }
                        } label: {
                            Label(
                                L10n.text(statisticsManager.isShowingSampleData ? "Live Data" : "Load Sample Data"),
                                systemImage: statisticsManager.isShowingSampleData ? "dot.radiowaves.left.and.right" : "sparkles"
                            )
                            .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        statisticsManager.refreshCurrentReport()
                    } label: {
                        Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .frame(height: statisticsRangeControlHeight)

                    rangeControls
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            rangePickerRow
            customRangeRow
        }
    }

    private var rangePickerRow: some View {
        HStack(spacing: statisticsRangeControlsGap) {
            LText("Range")
                .frame(width: statisticsRangeLabelColumnWidth, height: statisticsRangeControlHeight, alignment: .trailing)

            Picker("", selection: $range) {
                ForEach(StatisticsRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: statisticsRangeControlHeight)
        }
    }

    private var customRangeRow: some View {
        HStack(spacing: statisticsRangeControlsGap) {
            Color.clear
                .frame(width: statisticsRangeLabelColumnWidth, height: statisticsRangeControlHeight)
            customRangeControl
                .frame(width: statisticsRangePickerWidth, height: statisticsRangeControlHeight, alignment: .leading)
        }
    }

    private var customRangeControl: some View {
        Group {
            if customRangeActive {
                activeCustomRangeControl
            } else {
                Button {
                    openCustomRangePopover()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.system(size: 13, weight: .medium))
                        LText("Custom date range")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(width: statisticsRangePickerWidth, height: statisticsRangeControlHeight)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .popover(isPresented: $showingCustomRangePopover, arrowEdge: .top) {
            customRangePopover
        }
    }

    private var activeCustomRangeControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 13, weight: .medium))
            Text(customRangeSummary)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
            Spacer()
            Button {
                clearCustomRange()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Clear custom date range")
            Button {
                openCustomRangePopover()
            } label: {
                LText("Change")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .frame(width: statisticsRangePickerWidth, height: statisticsRangeControlHeight)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var customRangePopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            LText("Custom Date Range")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    LText("From")
                        .frame(width: 42, alignment: .leading)
                    DatePicker("", selection: $customDraftStart, in: ...customDraftEnd, displayedComponents: [.date])
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .frame(width: 150, alignment: .leading)
                }
                HStack(spacing: 12) {
                    LText("To")
                        .frame(width: 42, alignment: .leading)
                    DatePicker("", selection: $customDraftEnd, in: customDraftStart...Date(), displayedComponents: [.date])
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .frame(width: 150, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                Button {
                    showingCustomRangePopover = false
                } label: {
                    LText("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    applyCustomRange()
                } label: {
                    LText("Apply")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 300)
    }

    @ViewBuilder
    private var content: some View {
        if statisticsManager.isLoading && statisticsManager.report == nil {
            VStack {
                Spacer()
                ProgressView(L10n.text("Loading statistics…"))
                Spacer()
            }
        } else if let report = statisticsManager.report, report.hasAdapterData || report.hasAppData {
            ScrollView {
                VStack(spacing: 18) {
                    if statisticsManager.isShowingSampleData {
                        sampleDataBanner
                    }
                    summaryCard(report)
                    if collectStatistics && !collectAppStatistics && !statisticsManager.isShowingSampleData {
                        appStatsDisabledBanner
                    }
                    HStack(alignment: .top, spacing: 18) {
                        adaptersCard(report)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(spacing: 18) {
                            appCard(
                                title: "Top Downloads",
                                subtitle: collectAppStatistics
                                    ? "Top 10 apps by received data."
                                    : "App statistics collection is currently off.",
                                rows: report.topDownloadApps,
                                color: statisticsDownloadColor
                            )
                            appCard(
                                title: "Top Uploads",
                                subtitle: collectAppStatistics
                                    ? "Top 10 apps by sent data."
                                    : "App statistics collection is currently off.",
                                rows: report.topUploadApps,
                                color: statisticsUploadColor
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(24)
            }
        } else {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: collectStatistics ? "chart.bar.xaxis" : "bolt.slash")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(L10n.text(collectStatistics ? "Not enough statistics yet" : "Statistics collection is off"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(localizedEmptyStateMessage)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                if !collectStatistics {
                    Button {
                        PreferencesWindowController.shared.show(monitor: monitor)
                    } label: {
                        LText("Open Preferences")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .padding(32)
        }
    }

    private var headerSubtitle: String {
        localizedHeaderSubtitle
    }

    private var localizedHeaderSubtitle: String {
        if statisticsManager.isShowingSampleData {
            return L10n.text("Previewing generated sample statistics for the last year. Live collection continues with your current preferences.")
        }
        if collectStatistics {
            if collectAppStatistics {
                let interval = StatisticsManager.appSamplingIntervalDescription
                return L10n.format("Adapter statistics are collected continuously while NetFluss runs. App statistics are sampled every %@.", interval)
            }
            return L10n.text("Adapter statistics are being collected. App statistics are currently disabled.")
        }
        return L10n.text("Statistics collection is disabled in Preferences.")
    }

    private var emptyStateMessage: String {
        localizedEmptyStateMessage
    }

    private var localizedEmptyStateMessage: String {
        if collectStatistics {
            return L10n.text("Keep NetFluss running for a while and this view will fill in with adapter and app history.")
        }
        return L10n.text("Enable statistics in Preferences to start collecting preset and custom date range network history.")
    }

    private var sampleDataBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                LText("Sample history loaded")
                    .font(.system(size: 14, weight: .semibold))
                LText("This is generated demo traffic so you can review the charts, adapter ranking, and top-app lists across all ranges.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }

    private var appStatsDisabledBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                LText("App statistics are disabled")
                    .font(.system(size: 14, weight: .semibold))
                LText("Turn them on in Preferences if you want top download and upload apps in this view.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                PreferencesWindowController.shared.show(monitor: monitor)
            } label: {
                LText("Preferences")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func summaryCard(_ report: StatisticsReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localizedReportTitle(report).uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                    LText("Download and upload history for the selected range.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 6) {
                    Text(localizedReportBucketTitle(report))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let coverageStart = report.coverageStart {
                        Text(L10n.format("Collecting since %@", coverageStart.formatted(date: .abbreviated, time: .omitted)))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if let lastAdapterSampleAt = report.lastAdapterSampleAt {
                        Text(L10n.format("Last adapter update %@", lastAdapterSampleAt.formatted(date: .omitted, time: .shortened)))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if collectAppStatistics, let lastAppSampleAt = report.lastAppSampleAt {
                        Text(L10n.format("Last app update %@", lastAppSampleAt.formatted(date: .omitted, time: .shortened)))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(alignment: .top, spacing: 18) {
                trafficPanel(
                    title: "Download",
                    totalBytes: report.totalDownloadBytes,
                    points: report.timeline,
                    keyPath: \.downloadBytes,
                    color: statisticsDownloadColor,
                    systemImage: "arrow.down",
                    report: report
                )

                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 1)

                trafficPanel(
                    title: "Upload",
                    totalBytes: report.totalUploadBytes,
                    points: report.timeline,
                    keyPath: \.uploadBytes,
                    color: statisticsUploadColor,
                    systemImage: "arrow.up",
                    report: report
                )
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private func trafficPanel(
        title: String,
        totalBytes: UInt64,
        points: [StatisticsTimelinePoint],
        keyPath: KeyPath<StatisticsTimelinePoint, UInt64>,
        color: Color,
        systemImage: String,
        report: StatisticsReport
    ) -> some View {
        let peakBytes = max(points.map { $0[keyPath: keyPath] }.max() ?? 0, 1)
        let averageBytes = points.isEmpty ? 0 : points.reduce(0) { $0 + $1[keyPath: keyPath] } / UInt64(points.count)
        let peakMegabytes = max(mbValue(peakBytes), 1)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.text(title), systemImage: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(color)

                    Text(formattedBytes(totalBytes))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    metricPill(title: "Peak", value: formattedBytes(peakBytes), color: color)
                    metricPill(title: "Avg", value: formattedBytes(averageBytes), color: color)
                }
            }

            Chart(points) { point in
                let value = mbValue(point[keyPath: keyPath])

                BarMark(
                    x: .value("Date", point.date),
                    y: .value(title, value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.92), color.opacity(0.32)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Date", point.date),
                    y: .value(title, value)
                )
                .foregroundStyle(color)
                .interpolationMethod(.catmullRom)

                RuleMark(y: .value("Peak", peakMegabytes))
                    .foregroundStyle(color.opacity(0.14))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: xAxisTickCount(for: report))) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [3, 4]))
                        .foregroundStyle(.secondary.opacity(0.16))
                    AxisValueLabel(format: axisDateFormat(for: report))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                        .foregroundStyle(.secondary.opacity(0.14))
                    AxisTick()
                        .foregroundStyle(.secondary.opacity(0.18))
                    AxisValueLabel {
                        if let megabytes = value.as(Double.self) {
                            Text(axisMegabyteLabel(megabytes))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYScale(domain: 0...(peakMegabytes * 1.18))
            .frame(height: 180)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func metricPill(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(L10n.text(title).uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.12))
        )
    }

    private func adaptersCard(_ report: StatisticsReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LText("Adapters")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            LText("Top adapters by transferred data for the selected range.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if report.adapters.isEmpty {
                LText("No adapter history yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                let peak = max(report.adapters.map(\.totalBytes).max() ?? 1, 1)
                VStack(spacing: 14) {
                    ForEach(report.adapters) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.name)
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Text(formattedBytes(row.totalBytes))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 10) {
                                Label(formattedBytes(row.downloadBytes), systemImage: "arrow.down")
                                    .font(.system(size: 12))
                                    .foregroundStyle(statisticsDownloadColor)
                                Label(formattedBytes(row.uploadBytes), systemImage: "arrow.up")
                                    .font(.system(size: 12))
                                    .foregroundStyle(statisticsUploadColor)
                                Spacer()
                            }

                            GeometryReader { geo in
                                let width = geo.size.width * CGFloat(Double(row.totalBytes) / Double(peak))
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.12))
                                    Capsule()
                                        .fill(statisticsDownloadColor.opacity(0.7))
                                        .frame(width: max(width, 8))
                                }
                            }
                            .frame(height: 8)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private func appCard(title: String, subtitle: String, rows: [StatisticsAppRow], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text(title))
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(L10n.text(subtitle))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if rows.isEmpty {
                Text(L10n.text(collectAppStatistics ? "No app history yet." : "Turn app statistics on in Preferences to populate this list."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(color)
                                .frame(width: 24, height: 24)
                                .background(
                                    Circle()
                                        .fill(color.opacity(0.12))
                                )
                            Text(row.name)
                                .font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(formattedBytes(row.bytes))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                                .monospacedDigit()
                                .frame(minWidth: 82, alignment: .trailing)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(color.opacity(0.12))
                                )
                                .layoutPriority(1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(bytes))
    }

    private func localizedReportTitle(_ report: StatisticsReport) -> String {
        L10n.text(report.displayTitle)
    }

    private func localizedReportBucketTitle(_ report: StatisticsReport) -> String {
        L10n.text(report.displayBucketTitle)
    }

    private func mbValue(_ bytes: UInt64) -> Double {
        Double(bytes) / 1_000_000.0
    }

    private var statisticsDownloadColor: Color {
        statisticsAccentColor(
            selectionKey: "downloadColor",
            customHexKey: "downloadColorHex",
            defaultSelection: "blue",
            fallback: .systemBlue
        )
    }

    private var statisticsUploadColor: Color {
        statisticsAccentColor(
            selectionKey: "uploadColor",
            customHexKey: "uploadColorHex",
            defaultSelection: "green",
            fallback: .systemOrange
        )
    }

    private func statisticsAccentColor(
        selectionKey: String,
        customHexKey: String,
        defaultSelection: String,
        fallback: NSColor
    ) -> Color {
        let selection = UserDefaults.standard.string(forKey: selectionKey) ?? defaultSelection
        let customHex = UserDefaults.standard.string(forKey: customHexKey) ?? ""
        let resolved = resolvedAccentNSColor(selection: selection, customHex: customHex, fallback: fallback)
        guard let rgb = resolved.usingColorSpace(.deviceRGB) else {
            return Color(nsColor: fallback)
        }

        let luminance = (0.2126 * rgb.redComponent) + (0.7152 * rgb.greenComponent) + (0.0722 * rgb.blueComponent)
        if luminance > 0.92 || luminance < 0.10 {
            return Color(nsColor: fallback)
        }
        return Color(nsColor: rgb)
    }

    private func loadSelectedReport() {
        if customRangeActive {
            statisticsManager.loadReport(customStart: customStart, customEnd: customEnd)
        } else {
            statisticsManager.loadReport(for: range)
        }
    }

    private var customRangeSummary: String {
        let startText = customStart.formatted(date: .numeric, time: .omitted)
        let endText = customEnd.formatted(date: .numeric, time: .omitted)
        return "\(startText) - \(endText)"
    }

    private func openCustomRangePopover() {
        customDraftStart = customStart
        customDraftEnd = min(customEnd, Date())
        showingCustomRangePopover = true
    }

    private func clearCustomRange() {
        customRangeActive = false
        showingCustomRangePopover = false
        statisticsManager.loadReport(for: range)
    }

    private func applyCustomRange() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: min(customDraftStart, customDraftEnd))
        let selectedEndDay = calendar.startOfDay(for: max(customDraftStart, customDraftEnd))
        let nextDay = calendar.date(byAdding: .day, value: 1, to: selectedEndDay) ?? selectedEndDay
        let end = min(Date(), nextDay.addingTimeInterval(-1))

        customStart = start
        customEnd = end
        customRangeActive = true
        showingCustomRangePopover = false
        statisticsManager.loadReport(customStart: start, customEnd: end)
    }

    private func axisDateFormat(for report: StatisticsReport) -> Date.FormatStyle {
        switch report.timelineGranularity {
        case .minute:
            return .dateTime.hour().minute()
        case .hour:
            return .dateTime.hour()
        case .day:
            return .dateTime.month(.abbreviated).day()
        case .month:
            return .dateTime.month(.abbreviated)
        }
    }

    private func xAxisTickCount(for report: StatisticsReport) -> Int {
        switch report.timelineGranularity {
        case .minute:
            return 6
        case .hour:
            return 6
        case .day:
            let days = max(Int(report.timelineEnd.timeIntervalSince(report.timelineStart) / 86_400), 1)
            if days <= 7 { return days }
            if days <= 31 { return 5 }
            return 6
        case .month:
            return 6
        }
    }

    private func axisMegabyteLabel(_ megabytes: Double) -> String {
        if megabytes >= 1_000 {
            return String(format: "%.1f GB", megabytes / 1_000)
        }
        if megabytes >= 10 {
            return String(format: "%.0f MB", megabytes)
        }
        return String(format: "%.1f MB", megabytes)
    }
}
