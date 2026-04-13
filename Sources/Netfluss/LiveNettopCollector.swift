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

final class LiveNettopCollector {
    var onSample: (([AppTraffic], Date) -> Void)?

    private let queue = DispatchQueue(label: "com.local.netfluss.nettop.live", qos: .utility)
    private var process: Process?
    private var outputHandle: FileHandle?
    private var buffer = Data()
    private var currentRows: [String] = []
    private var sampleCount: UInt64 = 0
    private var lastSampleTime: Date?
    private var running = false

    var isRunning: Bool {
        queue.sync { running }
    }

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func startLocked() {
        guard process == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q",
            "/dev/null",
            "/usr/bin/nettop",
            "-P",
            "-d",
            "-x",
            "-L",
            "0",
            "-s",
            "1",
            "-J",
            "bytes_in,bytes_out"
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async {
                self?.consume(data)
            }
        }

        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.cleanupLocked()
            }
        }

        do {
            try process.run()
            self.process = process
            self.outputHandle = stdoutPipe.fileHandleForReading
            self.buffer.removeAll(keepingCapacity: false)
            self.currentRows.removeAll(keepingCapacity: false)
            self.sampleCount = 0
            self.lastSampleTime = nil
            self.running = true
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.outputHandle = nil
            self.running = false
        }
    }

    private func stopLocked() {
        outputHandle?.readabilityHandler = nil
        outputHandle = nil

        if let process {
            if process.isRunning {
                process.terminate()
            }
            self.process = nil
        }

        cleanupLocked()
    }

    private func cleanupLocked() {
        buffer.removeAll(keepingCapacity: false)
        currentRows.removeAll(keepingCapacity: false)
        sampleCount = 0
        lastSampleTime = nil
        running = false
        process = nil
        outputHandle = nil
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else {
            cleanupLocked()
            return
        }

        buffer.append(data)

        while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer[..<newlineRange.lowerBound]
            buffer.removeSubrange(..<newlineRange.upperBound)

            guard var line = String(data: lineData, encoding: .utf8) else { continue }
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            processLine(line)
        }
    }

    private func processLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed == ",bytes_in,bytes_out," {
            flushCurrentSample()
            return
        }

        currentRows.append(trimmed)
    }

    private func flushCurrentSample() {
        let sampleTime = Date()
        defer {
            currentRows.removeAll(keepingCapacity: true)
            sampleCount &+= 1
            lastSampleTime = sampleTime
        }

        guard !currentRows.isEmpty else { return }
        guard sampleCount > 0 else { return } // First sample is the baseline for delta mode.

        let elapsed = max(sampleTime.timeIntervalSince(lastSampleTime ?? sampleTime.addingTimeInterval(-1)), 0.1)
        let deltas = parseRows(currentRows)
        let apps = ProcessNetworkSampler.rates(from: deltas, elapsed: elapsed, limit: Int.max)
        guard let onSample else { return }

        DispatchQueue.main.async {
            onSample(apps, sampleTime)
        }
    }

    private func parseRows(_ rows: [String]) -> [String: (rx: UInt64, tx: UInt64)] {
        ProcessNetworkSampler.clearNameCacheIfNeeded()

        var totals: [String: (rx: UInt64, tx: UInt64)] = [:]
        totals.reserveCapacity(rows.count)

        for row in rows {
            let parts = row.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }

            let rawIdentifier = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = ProcessNetworkSampler.pid(from: rawIdentifier) else { continue }

            let downloadBytes = UInt64(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let uploadBytes = UInt64(String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            guard downloadBytes > 0 || uploadBytes > 0 else { continue }

            let name = ProcessNetworkSampler.cachedProcessName(for: pid)
            let existing = totals[name] ?? (rx: 0, tx: 0)
            totals[name] = (
                rx: existing.rx + downloadBytes,
                tx: existing.tx + uploadBytes
            )
        }

        return totals
    }
}
