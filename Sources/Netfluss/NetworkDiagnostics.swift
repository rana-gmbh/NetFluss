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

import Foundation

/// Captures rolling per-interface samples so we can dump them to the clipboard
/// when investigating reports like https://github.com/rana-gmbh/NetFluss/issues/31
/// (download stays at 0.00 on the physical adapter on some Macs).
///
/// The diagnostic records every NetworkMonitor tick into a ring buffer. The user
/// triggers a 30 s capture from the context menu; after the window closes, the
/// formatted dump is copied to the pasteboard for pasting into a GitHub issue.
@MainActor
final class NetworkDiagnostics {
    struct Snapshot {
        let date: Date
        let adapters: [AdapterStatus]
    }

    /// Default capture window — long enough for the user to start a download and
    /// see two or three tick samples that actually show traffic.
    nonisolated static let defaultCaptureDuration: TimeInterval = 30

    private var ring: [Snapshot] = []
    private var captureDeadline: Date?
    private var captureStart: Date?
    private let maxBufferedSnapshots = 240   // ~4 min at a 1 s tick

    var isCapturing: Bool { captureDeadline != nil }

    func record(adapters: [AdapterStatus], at date: Date) {
        ring.append(Snapshot(date: date, adapters: adapters))
        if ring.count > maxBufferedSnapshots {
            ring.removeFirst(ring.count - maxBufferedSnapshots)
        }
        if let deadline = captureDeadline, date >= deadline {
            // The deadline elapsing doesn't end the capture state itself — the
            // caller is responsible for finishing it. We just stop expanding
            // the captured window so trailing ticks aren't lumped in.
        }
    }

    @discardableResult
    func beginCapture(duration: TimeInterval = defaultCaptureDuration) -> Date {
        ring.removeAll(keepingCapacity: true)
        let now = Date()
        captureStart = now
        let deadline = now.addingTimeInterval(duration)
        captureDeadline = deadline
        return deadline
    }

    /// Finish the capture (the caller is expected to wait until the deadline
    /// before invoking this). Returns the formatted dump and the number of
    /// snapshots that were collected.
    func finishCapture() -> (dump: String, snapshotCount: Int) {
        let start = captureStart
        captureDeadline = nil
        captureStart = nil
        let dump = formattedDump(start: start)
        return (dump, ring.count)
    }

    func formattedDump(start: Date? = nil) -> String {
        var lines: [String] = []

        let now = Date()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let arch: String = {
            #if arch(arm64)
            return "arm64"
            #elseif arch(x86_64)
            return "x86_64"
            #else
            return "unknown"
            #endif
        }()

        lines.append("=== NetFluss network diagnostics ===")
        lines.append("Generated: \(dateFormatter.string(from: now))")
        lines.append("NetFluss:  \(version) (build \(build))")
        lines.append("macOS:     \(osVersion)")
        lines.append("Arch:      \(arch)")

        if let start {
            let durationSeconds = now.timeIntervalSince(start)
            lines.append(String(format: "Window:    %.1f s (%d snapshots)", durationSeconds, ring.count))
        } else {
            lines.append("Window:    \(ring.count) snapshots in ring buffer")
        }
        lines.append("")

        guard let firstSnapshot = ring.first, let lastSnapshot = ring.last else {
            lines.append("(no samples were captured — is NetworkMonitor running?)")
            return lines.joined(separator: "\n")
        }

        let zero = firstSnapshot.date

        // Build the union of adapter IDs seen during capture, preserving the
        // order the kernel returned them in.
        var adapterOrder: [String] = []
        var seen = Set<String>()
        var latestAdapter: [String: AdapterStatus] = [:]
        var firstAdapter: [String: AdapterStatus] = [:]

        for snapshot in ring {
            for adapter in snapshot.adapters {
                if !seen.contains(adapter.id) {
                    seen.insert(adapter.id)
                    adapterOrder.append(adapter.id)
                    firstAdapter[adapter.id] = adapter
                }
                latestAdapter[adapter.id] = adapter
            }
        }

        // Summary section --------------------------------------------------
        lines.append("=== Interfaces observed ===")
        for id in adapterOrder {
            guard let latest = latestAdapter[id] else { continue }
            let typeString: String
            switch latest.type {
            case .wifi: typeString = "wifi"
            case .ethernet: typeString = "ethernet"
            case .other: typeString = "other"
            }
            let upString = latest.isUp ? "up" : "down"
            let tunnelString = latest.isTunnelInterface ? " tunnel" : ""
            let linkString = latest.linkSpeedBps.map { String(format: " link=%.0f Mbps", Double($0) / 1_000_000) } ?? ""
            let wifiString = latest.wifiSSID.map { " ssid=\"\($0)\"" } ?? ""
            lines.append("  \(latest.id)  [\(latest.displayName)]  type=\(typeString) \(upString)\(tunnelString)\(linkString)\(wifiString)")
        }
        lines.append("")

        // Totals delta over the window ------------------------------------
        let firstTime = firstSnapshot.date
        let lastTime = lastSnapshot.date
        let windowSeconds = lastTime.timeIntervalSince(firstTime)
        lines.append("=== Per-interface byte deltas across window ===")
        lines.append(String(format: "Window: %.2f s", windowSeconds))
        lines.append("  "
                     + Self.padLeft("iface", 10)
                     + " " + Self.padRight("Δrx (bytes)", 16)
                     + " " + Self.padRight("Δtx (bytes)", 16)
                     + " " + Self.padRight("avg rx B/s", 12)
                     + " " + Self.padRight("avg tx B/s", 12))
        for id in adapterOrder {
            guard let first = firstAdapter[id], let last = latestAdapter[id] else { continue }
            let drx = last.rxBytes >= first.rxBytes ? last.rxBytes - first.rxBytes : 0
            let dtx = last.txBytes >= first.txBytes ? last.txBytes - first.txBytes : 0
            let rxRate = windowSeconds > 0 ? Double(drx) / windowSeconds : 0
            let txRate = windowSeconds > 0 ? Double(dtx) / windowSeconds : 0
            lines.append("  "
                         + Self.padLeft(id, 10)
                         + " " + Self.padRight("\(drx)", 16)
                         + " " + Self.padRight("\(dtx)", 16)
                         + " " + Self.padRight(String(format: "%.0f", rxRate), 12)
                         + " " + Self.padRight(String(format: "%.0f", txRate), 12))
        }
        lines.append("")

        // Per-interface time series ---------------------------------------
        for id in adapterOrder {
            lines.append("--- \(id) ---")
            lines.append("  "
                         + Self.padRight("t (s)", 7)
                         + "  " + Self.padRight("rxBytes", 18)
                         + "  " + Self.padRight("txBytes", 18)
                         + "  " + Self.padRight("rxRate B/s", 12)
                         + "  " + Self.padRight("txRate B/s", 12))
            for snapshot in ring {
                guard let adapter = snapshot.adapters.first(where: { $0.id == id }) else { continue }
                let t = snapshot.date.timeIntervalSince(zero)
                lines.append("  "
                             + Self.padRight(String(format: "%+.2f", t), 7)
                             + "  " + Self.padRight("\(adapter.rxBytes)", 18)
                             + "  " + Self.padRight("\(adapter.txBytes)", 18)
                             + "  " + Self.padRight(String(format: "%.0f", adapter.rxRateBps), 12)
                             + "  " + Self.padRight(String(format: "%.0f", adapter.txRateBps), 12))
            }
            lines.append("")
        }

        lines.append("=== end ===")
        return lines.joined(separator: "\n")
    }

    private static func padRight(_ s: String, _ width: Int) -> String {
        let count = s.count
        if count >= width { return s }
        return s + String(repeating: " ", count: width - count)
    }

    private static func padLeft(_ s: String, _ width: Int) -> String {
        let count = s.count
        if count >= width { return s }
        return String(repeating: " ", count: width - count) + s
    }
}
