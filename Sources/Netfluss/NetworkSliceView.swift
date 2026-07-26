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

struct NetworkSliceView: View {
    @EnvironmentObject private var manager: NetworkSliceManager
    @AppStorage("useBits") private var useBits: Bool = false
    @AppStorage("networkSliceHostsLive") private var hostsLiveMode: Bool = false
    @AppStorage("networkSliceServicesLive") private var servicesLiveMode: Bool = false
    @AppStorage("networkSliceAppsLive") private var appsLiveMode: Bool = false
    @State private var selectedDetail: SliceDetailSelection?

    private struct SliceDetailSelection: Equatable {
        enum Kind { case host, service, program }
        let kind: Kind
        let entry: NetworkSliceEntry

        var animationID: String { "\(kind)|\(entry.id)" }
    }

    private var downloadColor: Color { downloadAccentColor(for: .system) }
    private var uploadColor: Color { uploadAccentColor(for: .system) }

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
            ZStack {
                ScrollView {
                    VStack(spacing: 18) {
                        trafficRateCard
                        columns
                    }
                    .padding(24)
                }
                if let selectedDetail {
                    sliceDetail(selectedDetail)
                        .zIndex(1)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .clipped()
            .animation(.easeInOut(duration: 0.22), value: selectedDetail?.animationID)
        }
        .background(AppTheme.system.backgroundColor ?? Color(NSColor.windowBackgroundColor))
        .frame(minWidth: 920, minHeight: 600)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                LText("Network Slice")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                LText("Who your Mac is talking to right now.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 20) {
                headerRate(
                    systemImage: "arrow.down",
                    rateBps: manager.currentTotals.rxRateBps,
                    sessionBytes: manager.sessionRxBytes,
                    color: downloadColor
                )
                headerRate(
                    systemImage: "arrow.up",
                    rateBps: manager.currentTotals.txRateBps,
                    sessionBytes: manager.sessionTxBytes,
                    color: uploadColor
                )

                Button {
                    manager.setPaused(!manager.isPaused)
                } label: {
                    Label(
                        L10n.text(manager.isPaused ? "Resume" : "Pause"),
                        systemImage: manager.isPaused ? "play.fill" : "pause.fill"
                    )
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private func headerRate(systemImage: String, rateBps: Double, sessionBytes: UInt64, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(RateFormatter.formatRate(rateBps, useBits: useBits))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(byteFormatter.string(fromByteCount: Int64(clamping: sessionBytes)))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Traffic rate chart

    private var trafficRateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("Traffic Rate", systemImage: "waveform.path.ecg")
                Spacer()
                legendDot(color: downloadColor, title: "Download")
                legendDot(color: uploadColor, title: "Upload")
            }

            if manager.ratePoints.count < 2 {
                LText("Gathering data…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                trafficChart
                    .frame(height: 180)
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private var trafficChart: some View {
        Chart {
            ForEach(manager.ratePoints) { point in
                AreaMark(
                    x: .value("Time", point.time),
                    y: .value("Download", point.rxRateBps),
                    series: .value("Series", "download")
                )
                .foregroundStyle(downloadColor.opacity(0.25))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", point.time),
                    y: .value("Download", point.rxRateBps),
                    series: .value("Series", "download-line")
                )
                .foregroundStyle(downloadColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)

                AreaMark(
                    x: .value("Time", point.time),
                    y: .value("Upload", -point.txRateBps),
                    series: .value("Series", "upload")
                )
                .foregroundStyle(uploadColor.opacity(0.25))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", point.time),
                    y: .value("Upload", -point.txRateBps),
                    series: .value("Series", "upload-line")
                )
                .foregroundStyle(uploadColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
            }

            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Color.secondary.opacity(0.25))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bps = value.as(Double.self) {
                        Text(RateFormatter.formatRate(abs(bps), useBits: useBits))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let time = value.as(Date.self) {
                        Text(time, format: .dateTime.hour().minute().second())
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    private func legendDot(color: Color, title: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            LText(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Columns

    private var columns: some View {
        HStack(alignment: .top, spacing: 18) {
            sliceColumn(
                title: "Network Hosts",
                systemImage: "globe",
                entries: hostsLiveMode ? manager.recentHosts : manager.hosts,
                showsHostIcons: true,
                liveMode: $hostsLiveMode,
                emptyMessage: hostsLiveMode ? "No active hosts right now." : nil
            ) { entry in
                selectedDetail = SliceDetailSelection(kind: .host, entry: entry)
            }
            sliceColumn(
                title: "Services",
                systemImage: "tag",
                entries: servicesLiveMode ? manager.recentServices : manager.services,
                showsHostIcons: false,
                liveMode: $servicesLiveMode,
                emptyMessage: servicesLiveMode ? "No active services right now." : nil
            ) { entry in
                selectedDetail = SliceDetailSelection(kind: .service, entry: entry)
            }
            sliceColumn(
                title: "Apps",
                systemImage: "app.badge",
                entries: appsLiveMode ? manager.recentPrograms : manager.programs,
                showsHostIcons: false,
                liveMode: $appsLiveMode,
                emptyMessage: appsLiveMode ? "No active apps right now." : nil
            ) { entry in
                selectedDetail = SliceDetailSelection(kind: .program, entry: entry)
            }
        }
    }

    private func sliceColumn(
        title: String,
        systemImage: String,
        entries: [NetworkSliceEntry],
        showsHostIcons: Bool,
        liveMode: Binding<Bool>? = nil,
        emptyMessage: String? = nil,
        onSelect: ((NetworkSliceEntry) -> Void)? = nil
    ) -> some View {
        let maxTotal = max(entries.map(\.totalBytes).max() ?? 1, 1)
        let displaysRates = liveMode?.wrappedValue == true

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle(title, systemImage: systemImage)
                Spacer()
                if let liveMode {
                    modeToggle(liveMode)
                }
            }

            if entries.isEmpty {
                LText(emptyMessage ?? (manager.hasSample ? "No traffic captured yet." : "Gathering data…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 11) {
                    ForEach(entries) { entry in
                        if let onSelect {
                            Button {
                                onSelect(entry)
                            } label: {
                                sliceRow(entry, maxTotal: maxTotal, showsHostIcons: showsHostIcons, isSelectable: true, displaysRates: displaysRates)
                            }
                            .buttonStyle(.plain)
                        } else {
                            sliceRow(entry, maxTotal: maxTotal, showsHostIcons: showsHostIcons, isSelectable: false, displaysRates: displaysRates)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    /// Live (last sample interval, shown as rates) vs. accumulated-session
    /// totals for a column.
    private func modeToggle(_ liveMode: Binding<Bool>) -> some View {
        HStack(spacing: 2) {
            modeButton(
                liveMode,
                live: true,
                systemImage: "bolt.fill",
                helpKey: "Live view — traffic from the last few seconds."
            )
            modeButton(
                liveMode,
                live: false,
                systemImage: "sum",
                helpKey: "Accumulated view — total traffic since this window was opened."
            )
        }
        .padding(2)
        .background(Capsule().fill(Color.secondary.opacity(0.10)))
    }

    private func modeButton(_ liveMode: Binding<Bool>, live: Bool, systemImage: String, helpKey: String) -> some View {
        let isActive = liveMode.wrappedValue == live
        return Button {
            liveMode.wrappedValue = live
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 18)
                .background(Capsule().fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L10n.text(helpKey))
    }

    private func sliceRow(_ entry: NetworkSliceEntry, maxTotal: UInt64, showsHostIcons: Bool, isSelectable: Bool, displaysRates: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if showsHostIcons {
                    hostIcon(entry)
                }
                Text(entry.label)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(
                    displaysRates
                        ? RateFormatter.formatRate(Double(entry.totalBytes) / max(manager.lastIntervalSeconds, 0.5), useBits: useBits)
                        : byteFormatter.string(fromByteCount: Int64(clamping: entry.totalBytes))
                )
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                if isSelectable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            trafficBar(entry, maxTotal: maxTotal)
                .padding(.leading, showsHostIcons ? 22 : 0)
        }
        .contentShape(Rectangle())
        .help(entry.detail ?? entry.label)
    }

    @ViewBuilder
    private func hostIcon(_ entry: NetworkSliceEntry) -> some View {
        if entry.isPrivateHost {
            Image(systemName: "house")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        } else if let flag = entry.flagEmoji {
            Text(flag)
                .font(.system(size: 12))
                .frame(width: 16)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
    }

    // MARK: - Detail (slide-in)

    private func sliceDetail(_ selection: SliceDetailSelection) -> some View {
        // Prefer the live entry so label/flag/hostname keep updating while open.
        let entry = liveEntry(for: selection)
        let rows = connectionRows(for: selection)

        return VStack(spacing: 0) {
            detailHeader(selection: selection, entry: entry, rows: rows)
            Divider()
            if rows.isEmpty {
                LText("Gathering data…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        detailTableHeader(selection.kind)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            detailRow(row, kind: selection.kind)
                                .background(
                                    index.isMultiple(of: 2)
                                        ? Color.clear
                                        : Color.secondary.opacity(0.05)
                                )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.system.backgroundColor ?? Color(NSColor.windowBackgroundColor))
    }

    private func liveEntry(for selection: SliceDetailSelection) -> NetworkSliceEntry {
        let lists: [[NetworkSliceEntry]]
        switch selection.kind {
        case .host: lists = [manager.hosts, manager.recentHosts]
        case .service: lists = [manager.services, manager.recentServices]
        case .program: lists = [manager.programs, manager.recentPrograms]
        }
        for list in lists {
            if let match = list.first(where: { $0.id == selection.entry.id }) {
                return match
            }
        }
        return selection.entry
    }

    private func connectionRows(for selection: SliceDetailSelection) -> [NetworkSliceConnectionRow] {
        switch selection.kind {
        case .host: return manager.connectionRows(forHost: selection.entry.id)
        case .service: return manager.connectionRows(forService: selection.entry.id)
        case .program: return manager.connectionRows(forProgram: selection.entry.id)
        }
    }

    private func detailHeader(selection: SliceDetailSelection, entry: NetworkSliceEntry, rows: [NetworkSliceConnectionRow]) -> some View {
        // Session totals from the connection table itself, so they are correct
        // no matter whether the entry was clicked in live or accumulated mode.
        let rxTotal = rows.reduce(UInt64(0)) { $0 &+ $1.rxBytes }
        let txTotal = rows.reduce(UInt64(0)) { $0 &+ $1.txBytes }

        return HStack(spacing: 14) {
            Button {
                selectedDetail = nil
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .help(L10n.text("Back"))

            detailHeaderIcon(selection: selection, entry: entry)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if let detail = entry.detail {
                        Text(detail)
                            .monospacedDigit()
                    }
                    Text(L10n.format("%d connections", rows.count))
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 18) {
                Label {
                    Text(byteFormatter.string(fromByteCount: Int64(clamping: rxTotal)))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(downloadColor)
                }
                Label {
                    Text(byteFormatter.string(fromByteCount: Int64(clamping: txTotal)))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(uploadColor)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func detailHeaderIcon(selection: SliceDetailSelection, entry: NetworkSliceEntry) -> some View {
        switch selection.kind {
        case .host:
            if entry.isPrivateHost {
                Image(systemName: "house")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if let flag = entry.flagEmoji {
                Text(flag)
                    .font(.system(size: 26))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .service:
            Image(systemName: "tag")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
        case .program:
            Image(systemName: "app.badge")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func detailTableHeader(_ kind: SliceDetailSelection.Kind) -> some View {
        HStack(spacing: 10) {
            detailHeaderCell(kind == .host ? "App" : "Host")
                .frame(maxWidth: .infinity, alignment: .leading)
            if kind == .service {
                detailHeaderCell("App")
                    .frame(width: 130, alignment: .leading)
            }
            detailHeaderCell("Local Port")
                .frame(width: 78, alignment: .trailing)
            detailHeaderCell("Remote Port")
                .frame(width: 88, alignment: .trailing)
            detailHeaderCell("Protocol")
                .frame(width: 62, alignment: .leading)
            if kind != .service {
                detailHeaderCell("Service")
                    .frame(width: 100, alignment: .leading)
            }
            detailHeaderCell("Download")
                .frame(width: 76, alignment: .trailing)
            detailHeaderCell("Upload")
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    private func detailHeaderCell(_ title: String) -> some View {
        Text(L10n.text(title).uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
            .lineLimit(1)
    }

    private func detailRow(_ row: NetworkSliceConnectionRow, kind: SliceDetailSelection.Kind) -> some View {
        HStack(spacing: 10) {
            Text(kind == .host ? row.processName : (manager.resolvedHostname(for: row.host) ?? row.host))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if kind == .service {
                Text(row.processName)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
            }
            Text(row.localPort.map(String.init) ?? "–")
                .frame(width: 78, alignment: .trailing)
            Text(row.remotePort.map(String.init) ?? "–")
                .frame(width: 88, alignment: .trailing)
            Text(row.protocolName)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            if kind != .service {
                Text(row.serviceKey.map(NetworkSliceSampler.serviceDisplayName(for:)) ?? "–")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 100, alignment: .leading)
            }
            Text(byteFormatter.string(fromByteCount: Int64(clamping: row.rxBytes)))
                .foregroundStyle(downloadColor)
                .frame(width: 76, alignment: .trailing)
            Text(byteFormatter.string(fromByteCount: Int64(clamping: row.txBytes)))
                .foregroundStyle(uploadColor)
                .frame(width: 76, alignment: .trailing)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .help("\(row.localAddress):\(row.localPort.map(String.init) ?? "–") → \(row.host):\(row.remotePort.map(String.init) ?? "–")")
    }

    private func trafficBar(_ entry: NetworkSliceEntry, maxTotal: UInt64) -> some View {
        GeometryReader { geometry in
            let fraction = Double(entry.totalBytes) / Double(maxTotal)
            let barWidth = max(geometry.size.width * CGFloat(fraction), 3)
            let rxFraction = entry.totalBytes > 0 ? Double(entry.rxBytes) / Double(entry.totalBytes) : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.10))
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(downloadColor)
                        .frame(width: barWidth * CGFloat(rxFraction))
                    Rectangle()
                        .fill(uploadColor)
                        .frame(width: barWidth * CGFloat(1 - rxFraction))
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 4)
    }

    // MARK: - Shared bits

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(L10n.text(title).uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
        }
    }
}
