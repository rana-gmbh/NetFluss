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

import Combine
import SwiftUI

// MARK: - Model

/// A stopwatch for traffic: once started it adds up the download / upload bytes
/// of every adapter that counts toward totals (the same rule as the Data Usage
/// section), until it is paused or reset. Lives outside the popover so it keeps
/// measuring while the popover is closed.
@MainActor
final class TrafficTimer: ObservableObject {
    enum State: String, Codable {
        case idle
        case running
        case paused
    }

    static let shared = TrafficTimer()

    @Published private(set) var state: State = .idle
    @Published private(set) var downloadBytes: UInt64 = 0
    @Published private(set) var uploadBytes: UInt64 = 0
    /// Time banked by earlier running stretches (excludes the current one).
    @Published private(set) var accumulated: TimeInterval = 0
    /// Start of the current running stretch; nil while idle or paused.
    @Published private(set) var runningSince: Date?
    /// When the session was first started (kept across pause / resume).
    @Published private(set) var startedAt: Date?
    /// When the session was last paused; nil while running or idle.
    @Published private(set) var pausedAt: Date?

    private var previousCounters: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var cancellable: AnyCancellable?
    private static let storageKey = "trafficTimerSession"

    private struct StoredSession: Codable {
        let state: State
        let downloadBytes: UInt64
        let uploadBytes: UInt64
        let elapsed: TimeInterval
        let startedAt: Date?
        let pausedAt: Date?
    }

    func attach(to monitor: NetworkMonitor) {
        restore()
        cancellable = monitor.$adapters.sink { [weak self] adapters in
            self?.ingest(adapters)
        }
    }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        accumulated + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    func toggle() {
        state == .running ? pause() : start()
    }

    func start() {
        guard state != .running else { return }
        // Re-baseline so traffic that flowed while paused is not counted.
        previousCounters = [:]
        let now = Date()
        if state == .idle { startedAt = now }
        pausedAt = nil
        runningSince = now
        state = .running
        persist()
    }

    func pause() {
        guard state == .running else { return }
        let now = Date()
        accumulated = elapsed(at: now)
        runningSince = nil
        pausedAt = now
        state = .paused
        persist()
    }

    func reset() {
        state = .idle
        downloadBytes = 0
        uploadBytes = 0
        accumulated = 0
        runningSince = nil
        startedAt = nil
        pausedAt = nil
        previousCounters = [:]
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    /// Saves the session so it survives a relaunch. A running session comes
    /// back paused — traffic while NetFluss wasn't running can't be counted.
    func persist() {
        guard state != .idle else {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
            return
        }
        let session = StoredSession(
            state: state,
            downloadBytes: downloadBytes,
            uploadBytes: uploadBytes,
            elapsed: elapsed(),
            startedAt: startedAt,
            // A running session is restored paused as of now (i.e. at quit).
            pausedAt: state == .running ? Date() : pausedAt
        )
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let session = try? JSONDecoder().decode(StoredSession.self, from: data),
              session.state != .idle else { return }
        state = .paused
        downloadBytes = session.downloadBytes
        uploadBytes = session.uploadBytes
        accumulated = session.elapsed
        startedAt = session.startedAt
        pausedAt = session.pausedAt
    }

    private func ingest(_ adapters: [AdapterStatus]) {
        guard state == .running else { return }
        let excludeTunnels = UserDefaults.standard.bool(forKey: "excludeTunnelAdaptersFromTotals")
        var download: UInt64 = 0
        var upload: UInt64 = 0
        var current: [String: (rx: UInt64, tx: UInt64)] = [:]

        for adapter in adapters where AdapterClassifier.countsTowardTotals(named: adapter.id, excludeTunnels: excludeTunnels) {
            current[adapter.id] = (adapter.rxBytes, adapter.txBytes)
            // A new adapter (or one whose counters reset) only sets a baseline.
            guard let previous = previousCounters[adapter.id] else { continue }
            if adapter.rxBytes >= previous.rx { download &+= adapter.rxBytes - previous.rx }
            if adapter.txBytes >= previous.tx { upload &+= adapter.txBytes - previous.tx }
        }

        previousCounters = current
        if download > 0 { downloadBytes &+= download }
        if upload > 0 { uploadBytes &+= upload }
    }
}

// MARK: - Popover section

struct TrafficTimerSection: View {
    @ObservedObject private var timer = TrafficTimer.shared
    @Environment(\.appTheme) private var theme
    @AppStorage("useBits") private var useBits: Bool = false

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
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 8)

            HStack(spacing: 0) {
                TimerControlButton(
                    systemImage: "arrow.counterclockwise",
                    tint: .secondary,
                    help: "Reset",
                    action: timer.reset
                )
                .disabled(timer.state == .idle)

                Spacer(minLength: 8)
                clock
                Spacer(minLength: 8)

                TimerControlButton(
                    systemImage: timer.state == .running ? "pause.fill" : "play.fill",
                    tint: timer.state == .running ? .orange : .green,
                    help: primaryHelp,
                    action: timer.toggle
                )
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)

            HStack(spacing: 0) {
                trafficCell(
                    icon: "arrow.down",
                    label: "Download",
                    color: downloadAccentColor(for: theme),
                    bytes: timer.downloadBytes
                )
                Divider()
                    .frame(height: 34)
                trafficCell(
                    icon: "arrow.up",
                    label: "Upload",
                    color: uploadAccentColor(for: theme),
                    bytes: timer.uploadBytes
                )
            }
            .padding(.top, 10)

            shareBar
                .padding(.horizontal, 14)
                .padding(.top, 9)
                .padding(.bottom, 12)
        }
    }

    private var primaryHelp: LocalizedStringKey {
        switch timer.state {
        case .idle: return "Start"
        case .running: return "Pause"
        case .paused: return "Resume"
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "stopwatch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            LText("Traffic Timer")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if timer.state != .idle {
                HStack(spacing: 4) {
                    Circle()
                        .fill(timer.state == .running ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                    LText(timer.state == .running ? "Running" : "Paused")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }
        }
    }

    // MARK: Clock

    @ViewBuilder
    private var clock: some View {
        if let since = timer.runningSince {
            // Tick on whole elapsed seconds (aligned to the start, including the
            // fraction banked before a pause) so the display never skips a second.
            let fraction = timer.accumulated.truncatingRemainder(dividingBy: 1)
            TimelineView(.periodic(from: since.addingTimeInterval(1 - fraction), by: 1)) { context in
                clockFace(elapsed: timer.elapsed(at: context.date))
            }
        } else {
            clockFace(elapsed: timer.elapsed())
        }
    }

    private func clockFace(elapsed: TimeInterval) -> some View {
        VStack(spacing: 2) {
            Text(Self.clockText(elapsed))
                .font(.system(size: 36, weight: .thin))
                .monospacedDigit()
                .foregroundStyle(timer.state == .paused ? Color.primary.opacity(0.55) : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 4) {
                Text(L10n.text("Total").uppercased())
                    .tracking(0.5)
                Text(formatted(timer.downloadBytes &+ timer.uploadBytes))
                    .monospacedDigit()
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)

            if let startedAt = timer.startedAt {
                VStack(spacing: 1) {
                    sessionTimeRow("Starting time", date: startedAt)
                    if timer.state == .paused, let pausedAt = timer.pausedAt {
                        sessionTimeRow("Paused at", date: pausedAt)
                    }
                }
                .padding(.top, 3)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static let sessionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func sessionTimeRow(_ label: String, date: Date) -> some View {
        Self.sessionDateFormatter.locale = AppLanguage.selected.locale
        return HStack(spacing: 3) {
            Text("\(L10n.text(label)):")
                .foregroundStyle(.secondary)
            Text(Self.sessionDateFormatter.string(from: date))
                .foregroundStyle(.primary.opacity(0.75))
                .monospacedDigit()
        }
        .font(.system(size: 9))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// "04:07" under an hour, "1:04:07" beyond — like a phone stopwatch without
    /// the hundredths (a 10 Hz redraw isn't worth it for traffic totals).
    static func clockText(_ elapsed: TimeInterval) -> String {
        let total = Int((elapsed + 0.02).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: Traffic

    private func trafficCell(icon: String, label: String, color: Color, bytes: UInt64) -> some View {
        let seconds = timer.elapsed()
        let average = seconds >= 1 ? Double(bytes) / seconds : 0
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text(label).uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Text(formatted(bytes))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                Text("⌀ \(RateFormatter.formatRate(average, useBits: useBits))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Slim download/upload split, in the arrow colours.
    private var shareBar: some View {
        let total = Double(timer.downloadBytes) + Double(timer.uploadBytes)
        let downloadShare = total > 0 ? Double(timer.downloadBytes) / total : 0
        return GeometryReader { geo in
            let spacing: CGFloat = total > 0 && downloadShare > 0 && downloadShare < 1 ? 2 : 0
            let usable = max(geo.size.width - spacing, 0)
            HStack(spacing: spacing) {
                if total > 0 {
                    Capsule()
                        .fill(downloadAccentColor(for: theme))
                        .frame(width: usable * downloadShare)
                    Capsule()
                        .fill(uploadAccentColor(for: theme))
                        .frame(width: usable * (1 - downloadShare))
                } else {
                    Capsule()
                        .fill(.quaternary)
                }
            }
        }
        .frame(height: 3)
        .animation(.easeInOut(duration: 0.4), value: downloadShare)
        .accessibilityHidden(true)
    }
}

// MARK: - Controls

/// Phone-stopwatch style round button: a tinted disc inside a thin outer ring.
private struct TimerControlButton: View {
    let systemImage: String
    let tint: Color
    let help: LocalizedStringKey
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1.2)
                Circle()
                    .fill(tint.opacity(0.18))
                    .padding(3.5)
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.opacity)
            }
            .frame(width: 46, height: 46)
            .contentShape(Circle())
        }
        .buttonStyle(TimerPressStyle())
        .opacity(isEnabled ? 1 : 0.35)
        .help(help)
        .animation(.easeInOut(duration: 0.15), value: systemImage)
    }
}

private struct TimerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
