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

/// A stand-in `DefguardControlClient` for developing and demoing the Defguard
/// UI and connect flow before the real gRPC agent exists. It fabricates a
/// plausible enrollment and accepts the TOTP code "000000" (any other code is
/// rejected, so the error path is exercisable too). NOT wired into release builds
/// — the real implementation will drive the bundled `defguard-agent`.
struct DefguardMockControlClient: DefguardControlClient {
    /// Simulated latency so the UI's progress states are visible while testing.
    var delay: Duration = .milliseconds(400)

    func enroll(instanceURL: String, token: String, deviceName: String) async throws -> DefguardEnrollmentResult {
        try? await Task.sleep(for: delay)
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DefguardError.enrollmentFailed("empty enrollment token")
        }
        let instance = DefguardInstance(
            name: URL(string: instanceURL)?.host ?? "Defguard",
            instanceURL: instanceURL,
            proxyURL: instanceURL,
            devicePublicKey: "mockDevicePublicKey0000000000000000000000000=",
            keychainAccount: "defguard-device-\(UUID().uuidString.prefix(8))"
        )
        let location = DefguardLocation(
            networkID: 1,
            name: "Office",
            assignedIP: "10.10.10.2/24",
            serverPublicKey: "mockServerPublicKey0000000000000000000000000=",
            endpoint: "vpn.example.com:51820",
            allowedIPs: ["0.0.0.0/0"],
            dns: ["10.10.10.1"],
            keepaliveInterval: 25,
            mfaMode: .internal
        )
        return DefguardEnrollmentResult(
            instance: instance,
            devicePrivateKey: "mockDevicePrivateKey000000000000000000000000=",
            devicePublicKey: "mockDevicePublicKey0000000000000000000000000=",
            locations: [location]
        )
    }

    func startMFA(instance: DefguardInstance, location: DefguardLocation,
                  method: DefguardMFAMethod) async throws -> DefguardMFAChallenge {
        try? await Task.sleep(for: delay)
        return DefguardMFAChallenge(method: method, token: "mock-mfa-token")
    }

    func finishMFA(instance: DefguardInstance, location: DefguardLocation,
                   challenge: DefguardMFAChallenge, code: String) async throws -> DefguardMFAResult {
        try? await Task.sleep(for: delay)
        guard code == "000000" else { throw DefguardError.invalidCode }
        return DefguardMFAResult(presharedKey: "mockPresharedKey00000000000000000000000000=", ttlSeconds: 180)
    }
}
