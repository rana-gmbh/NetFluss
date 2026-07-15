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

import SwiftUI
import AppKit

/// Popover "Data Usage" section: a compact upload / download / total summary for
/// today and the current calendar month, read from the historical statistics
/// the app already collects. Only rendered when statistics collection is on (see
/// `MenuBarView.isSectionVisible`), so it never needs an empty/off state itself.
struct UsageSummarySection: View {
    @EnvironmentObject private var statisticsManager: StatisticsManager
    @Environment(\.appTheme) private var theme
    @State private var isHoveringStats = false

    /// Cumulative-byte formatter, matching the Statistics window
    /// (`StatisticsView.byteFormatter`) so the two surfaces read identically.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .decimal
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        return formatter
    }()

    private func formatted(_ bytes: UInt64) -> String {
        Self.byteFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    var body: some View {
        let summary = statisticsManager.usageSummary
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Data Usage")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    StatisticsWindowController.shared.show(manager: statisticsManager)
                } label: {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 11))
                        .foregroundStyle(isHoveringStats ? Color.primary : Color.secondary)
                        .animation(.easeInOut(duration: 0.12), value: isHoveringStats)
                }
                .buttonStyle(.borderless)
                .help("Bandwidth Statistics")
                .onHover { hovering in
                    guard hovering != isHoveringStats else { return }
                    isHoveringStats = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .onDisappear {
                    if isHoveringStats {
                        NSCursor.pop()
                        isHoveringStats = false
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    Text("")
                        .gridColumnAlignment(.leading)
                    columnHeader("Today")
                    columnHeader("This Month")
                }
                usageRow(
                    "Upload",
                    icon: "arrow.up",
                    color: uploadAccentColor(for: theme),
                    today: summary.today.uploadBytes,
                    month: summary.month.uploadBytes
                )
                usageRow(
                    "Download",
                    icon: "arrow.down",
                    color: downloadAccentColor(for: theme),
                    today: summary.today.downloadBytes,
                    month: summary.month.downloadBytes
                )
                Divider()
                    .gridCellColumns(3)
                usageRow(
                    "Total",
                    icon: nil,
                    color: .primary,
                    today: summary.today.totalBytes,
                    month: summary.month.totalBytes,
                    emphasized: true
                )
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        // Refresh when the section becomes visible so the numbers are current
        // even after an idle stretch with no new adapter deltas. Live updates
        // while the popover stays open are driven by StatisticsManager.
        .onAppear { statisticsManager.refreshUsageSummary() }
    }

    private func columnHeader(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }

    @ViewBuilder
    private func usageRow(
        _ titleKey: String,
        icon: String?,
        color: Color,
        today: UInt64,
        month: UInt64,
        emphasized: Bool = false
    ) -> some View {
        let weight: Font.Weight = emphasized ? .semibold : .regular
        GridRow {
            HStack(spacing: 6) {
                Image(systemName: icon ?? "circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 12)
                    .opacity(icon == nil ? 0 : 1)
                Text(LocalizedStringKey(titleKey))
                    .font(.system(size: 11, weight: weight))
                    .foregroundStyle(emphasized ? Color.primary : Color.secondary)
            }
            Text(formatted(today))
                .font(.system(size: 11, weight: weight))
                .monospacedDigit()
            Text(formatted(month))
                .font(.system(size: 11, weight: weight))
                .monospacedDigit()
        }
    }
}
