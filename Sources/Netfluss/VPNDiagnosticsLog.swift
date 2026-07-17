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
import AppKit
import NetflussHelperShared

/// A human-readable diagnostics log for the VPN client, so users can send us
/// exactly what happened during a connection attempt (the resolved binaries and
/// their architecture, the command the helper ran, and the tool's full output).
/// This is what turns "it doesn't work" into an actionable bug report.
///
/// Written to Application Support/Netfluss/VPN/diagnostics.log, size-capped, and
/// surfaced in Preferences → VPN via Copy / Reveal / Clear.
final class VPNDiagnosticsLog {
    static let shared = VPNDiagnosticsLog()

    private let queue = DispatchQueue(label: "com.local.netfluss.vpndiag")
    private let maxBytes = 256 * 1024

    let fileURL: URL

    private init() {
        let fm = FileManager.default
        let base = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent("Netfluss/VPN", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("diagnostics.log")
    }

    /// Append one timestamped line. Thread-safe; never throws to callers.
    func log(_ message: String) {
        queue.async { [self] in
            let line = "[\(Self.timestamp())] \(message)\n"
            append(line)
        }
    }

    /// Append a multi-line block verbatim (e.g. a tool's captured output), framed
    /// so it's easy to read in the log.
    func logBlock(_ title: String, _ body: String) {
        queue.async { [self] in
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let block = "[\(Self.timestamp())] ── \(title) ──\n\(trimmed.isEmpty ? "(empty)" : trimmed)\n──────────\n"
            append(block)
        }
    }

    /// Record a one-time environment snapshot at the start of a connection attempt
    /// — the single most useful thing for diagnosing arch / stale-helper issues.
    func logEnvironment(registeredHelperPath: String?, registeredHelperVersion: Int) {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let bundlePath = Bundle.main.bundlePath
        // Run the `file` architecture probes off the main thread.
        queue.async { [self] in
            var lines: [String] = []
            lines.append("NetFluss \(short) (build \(build)), helperVersion \(NetflussHelperConstants.helperVersion)")
            lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            lines.append("app process arch: \(Self.runningArch)")
            lines.append("app bundle: \(bundlePath)")
            lines.append("helper registered from: \(registeredHelperPath ?? "(unknown)") [v\(registeredHelperVersion)]")
            let vpnDir = bundlePath + "/Contents/Library/VPN"
            for tool in ["openvpn", "wireguard-go", "wg", "bash"] {
                lines.append("  \(tool): \(Self.fileArch(vpnDir + "/" + tool))")
            }
            let body = lines.joined(separator: "\n")
            append("[\(Self.timestamp())] ── environment ──\n\(body)\n──────────\n")
        }
    }

    func readAll() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func clear() {
        queue.async { [self] in try? "".write(to: fileURL, atomically: true, encoding: .utf8) }
    }

    @MainActor func copyToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(readAll(), forType: .string)
    }

    @MainActor func revealInFinder() {
        // Ensure the file exists so Finder has something to select.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: - Internals (queue-confined)

    private func append(_ text: String) {
        let existing = (try? Data(contentsOf: fileURL)) ?? Data()
        var data = existing
        data.append(Data(text.utf8))
        if data.count > maxBytes {
            // Keep the newest ~maxBytes, trimmed to a line boundary.
            let tail = data.suffix(maxBytes)
            if let nl = tail.firstIndex(of: 0x0A) {
                data = Data(tail[(nl + 1)...])
            } else {
                data = Data(tail)
            }
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    private static var runningArch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// `file -b <path>` for a concise architecture line (e.g. "Mach-O universal
    /// binary with 2 architectures…"). Empty/absent files are reported plainly.
    private static func fileArch(_ path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "(missing)" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        p.arguments = ["-b", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "(file failed: \(error.localizedDescription))" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(unreadable)"
    }
}
