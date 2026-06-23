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
            services.append(Service(name: name, kind: kind))
        }
        return services
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
