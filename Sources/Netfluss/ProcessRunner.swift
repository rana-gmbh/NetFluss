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

/// Runs short-lived system tools (`networksetup`, `netstat`, `scutil`, …).
enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        /// False when the tool couldn't be started at all.
        var launched: Bool
        var timedOut: Bool

        var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
        var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    /// How long a tool gets to exit on SIGTERM before it is killed outright.
    private static let killGrace: TimeInterval = 2

    /// Blocks until the tool exits or `timeout` passes.
    ///
    /// A hung `networksetup` used to hang its caller for good: `dnsChanging`
    /// stayed on, and with it the DNS rules. Both pipes are drained at once, since
    /// reading them in turn deadlocks when the tool fills the one not being read.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        guard (try? process.run()) != nil else {
            return Output(status: -1, stdout: Data(), stderr: Data(), launched: false, timedOut: false)
        }

        let lock = NSLock()
        var timedOut = false
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            lock.lock(); timedOut = true; lock.unlock()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        var stderrData = Data()
        let stderrDone = DispatchGroup()
        stderrDone.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrDone.leave()
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        stderrDone.wait()
        process.waitUntilExit()
        watchdog.cancel()

        lock.lock(); defer { lock.unlock() }
        return Output(
            status: process.terminationStatus,
            stdout: stdoutData,
            stderr: stderrData,
            launched: true,
            timedOut: timedOut
        )
    }

    private static let blockingQueue = DispatchQueue(
        label: "com.local.netfluss.blocking",
        qos: .utility,
        attributes: .concurrent
    )

    /// Does blocking work on its own queue and awaits the result. Waiting for a
    /// process inside a `Task` ties up a thread of Swift's small shared pool, which
    /// on a two-core Intel Mac can stall every other task in the app.
    static func offloaded<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            blockingQueue.async { continuation.resume(returning: work()) }
        }
    }
}
