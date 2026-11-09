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
import SystemConfiguration

/// Controls macOS-native VPN services (IKEv2 / IPsec / L2TP) via `scutil --nc`.
/// These are the VPNs configured in System Settings or installed from a provider
/// `.mobileconfig`; NetFluss starts/stops/queries them. Run as the user (native
/// VPNs are per-session), so no privileged helper is needed and no special
/// entitlement — unlike a Network Extension.
enum NativeVPN {
    struct Service: Identifiable, Equatable, Sendable {
        var id: String { name }
        let name: String
        let kind: String   // e.g. "IKEv2", "L2TP", "IPSec"
        /// SystemConfiguration's id for the service, which status callbacks need.
        var serviceID: String? = nil
    }

    /// Configured native VPN services, parsed from `scutil --nc list`.
    static func list() -> [Service] {
        let output = run(["--nc", "list"]) ?? ""
        var services: [Service] = []
        for line in output.split(whereSeparator: \.isNewline) {
            // * (Disconnected)   <UUID> PPP --> L2TP   "Name"   [PPP:L2TP]
            guard let nameStart = line.firstIndex(of: "\""),
                  let nameEnd = line[line.index(after: nameStart)...].firstIndex(of: "\"") else { continue }
            let name = String(line[line.index(after: nameStart)..<nameEnd])
            var kind = "VPN"
            if let lb = line.lastIndex(of: "["), let rb = line.lastIndex(of: "]"), lb < rb {
                kind = String(line[line.index(after: lb)..<rb])
            }
            services.append(Service(name: name, kind: kind, serviceID: serviceID(inListLine: String(line[..<nameStart]))))
        }
        return services
    }

    /// The service id in the part of a `scutil --nc list` line before the name:
    /// `* (Disconnected)   4F3E…-…   IPSec`.
    static func serviceID(inListLine prefix: String) -> String? {
        prefix.split(whereSeparator: \.isWhitespace)
            .first { UUID(uuidString: String($0)) != nil }
            .map(String.init)
    }

    /// Current status word ("Connected", "Connecting", "Disconnected", …).
    static func status(_ service: String) -> String {
        (run(["--nc", "status", service])?
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? "Unknown")
            .trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    static func start(_ service: String) -> Bool {
        run(["--nc", "start", service]) != nil
    }

    @discardableResult
    static func stop(_ service: String) -> Bool {
        run(["--nc", "stop", service]) != nil
    }

    private static func run(_ args: [String]) -> String? {
        let result = ProcessRunner.run("/usr/sbin/scutil", args)
        guard result.launched, result.status == 0 else { return nil }
        return result.stdoutText
    }
}


/// Follows one system VPN service through SystemConfiguration's status
/// callback, so a drop or a change made in System Settings shows up at once
/// without polling `scutil`.
@MainActor
final class NativeVPNWatcher {
    enum State: Equatable {
        case connecting, connected, disconnecting, disconnected
    }

    private var connection: SCNetworkConnection?
    private let onChange: (State) -> Void
    private var lastState: State?

    init?(serviceID: String, onChange: @escaping (State) -> Void) {
        self.onChange = onChange
        // Every stored property is set, so self can be handed to the callback.
        // Unretained: `invalidate()` unschedules before the watcher goes away.
        var context = SCNetworkConnectionContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: SCNetworkConnectionCallBack = { _, status, info in
            guard let info else { return }
            let watcher = Unmanaged<NativeVPNWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.deliver(status) }
        }
        guard let connection = SCNetworkConnectionCreateWithServiceID(nil, serviceID as CFString, callback, &context) else {
            return nil
        }
        self.connection = connection
    }

    /// Start receiving changes on the main run loop, and report the state now.
    func start() {
        guard let connection else { return }
        SCNetworkConnectionScheduleWithRunLoop(connection, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        deliver(SCNetworkConnectionGetStatus(connection))
    }

    /// Must run before the watcher goes away: the callback holds it unretained.
    func invalidate() {
        guard let connection else { return }
        SCNetworkConnectionUnscheduleFromRunLoop(connection, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.connection = nil
    }

    private func deliver(_ status: SCNetworkConnectionStatus) {
        let state: State
        switch status {
        case .connected: state = .connected
        case .connecting: state = .connecting
        case .disconnecting: state = .disconnecting
        default: state = .disconnected   // .disconnected and .invalid
        }
        guard state != lastState else { return }
        lastState = state
        onChange(state)
    }
}
