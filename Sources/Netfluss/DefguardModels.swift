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

// Transport-agnostic model layer for Defguard support (issue #51). Defguard is
// stock WireGuard plus an MFA/identity control plane: for MFA locations the
// gateway only admits the peer once the client completes MFA and receives a
// pre-shared key (a rotating session token). See Docs/Defguard.md.
//
// These types are independent of how we actually talk to the Defguard proxy
// (planned: a bundled Go `defguard-agent` speaking gRPC — grpc-swift needs
// macOS 15, so pure-Swift gRPC is not an option on our macOS 13 floor).

/// A Defguard server the user has enrolled a device with. Phase 1 supports a
/// single instance; the model already allows several so we don't have to migrate.
struct DefguardInstance: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// The core/instance base URL the user pastes when enrolling.
    var instanceURL: String
    /// The public proxy ("Edge") gRPC endpoint the client actually dials for
    /// enrollment and MFA; returned by enrollment.
    var proxyURL: String
    /// This device's WireGuard public key (not secret; needed to identify the
    /// peer in client-MFA requests). The matching private key is in the Keychain.
    var devicePublicKey: String
    /// Keychain account holding this device's WireGuard private key (never stored
    /// on disk in plaintext).
    var keychainAccount: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, instanceURL: String, proxyURL: String,
         devicePublicKey: String, keychainAccount: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.instanceURL = instanceURL
        self.proxyURL = proxyURL
        self.devicePublicKey = devicePublicKey
        self.keychainAccount = keychainAccount
        self.createdAt = createdAt
    }
}

/// How a location gates access. Mirrors Defguard's `location_mfa_mode`.
enum DefguardMFAMode: String, Codable, Sendable {
    case disabled      // plain WireGuard — no per-session MFA
    case `internal`    // Defguard's built-in MFA (TOTP / email / biometric)
    case external      // external SSO / OIDC (paid tier; out of Phase 1 scope)
}

/// MFA methods we may offer. Phase 1 implements `totp` only.
enum DefguardMFAMethod: String, Codable, Sendable, CaseIterable {
    case totp
    case email
    case oidc
    case biometric
}

/// One Defguard "location" = one WireGuard peer/network, from the enrollment
/// `DeviceConfig`. These map straight onto a WireGuard `[Interface]`/`[Peer]`.
struct DefguardLocation: Codable, Equatable, Sendable {
    var networkID: Int
    var name: String
    /// Address assigned to this device on the network (WireGuard `Address`).
    var assignedIP: String
    /// Server (peer) public key.
    var serverPublicKey: String
    /// `host:port` WireGuard endpoint.
    var endpoint: String
    var allowedIPs: [String]
    var dns: [String]
    var keepaliveInterval: Int
    var mfaMode: DefguardMFAMode

    var requiresMFA: Bool { mfaMode != .disabled }
}

/// Result of enrolling a device: the instance, the freshly generated device
/// private key (to be stored in the Keychain by the caller), and the locations.
struct DefguardEnrollmentResult: Sendable {
    var instance: DefguardInstance
    var devicePrivateKey: String
    var devicePublicKey: String
    var locations: [DefguardLocation]
}

/// A pending MFA challenge (e.g. "enter your TOTP code"). Extra fields (chosen
/// method, opaque server token) are carried so `finish` can reference them.
struct DefguardMFAChallenge: Sendable {
    var method: DefguardMFAMethod
    var token: String?
}

/// Successful MFA: the authorizing pre-shared key plus how long the session is
/// good for before the gateway drops the peer (used to schedule re-auth).
struct DefguardMFAResult: Sendable {
    var presharedKey: String
    var ttlSeconds: Int?
}

/// A persisted, enrolled Defguard instance and the locations it provisioned. The
/// device private key is NOT here — it lives in the Keychain under
/// `instance.keychainAccount`.
struct DefguardProfile: Identifiable, Codable, Equatable, Sendable {
    var instance: DefguardInstance
    var locations: [DefguardLocation]
    var id: UUID { instance.id }
}

enum DefguardError: LocalizedError {
    case enrollmentFailed(String)
    case mfaFailed(String)
    case invalidCode
    case agentUnavailable
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .enrollmentFailed(let m): return "Defguard enrollment failed: \(m)"
        case .mfaFailed(let m): return "Defguard MFA failed: \(m)"
        case .invalidCode: return "That authentication code was not accepted."
        case .agentUnavailable: return "The Defguard agent is unavailable."
        case .notImplemented: return "Defguard support is not available in this build yet."
        }
    }
}

/// The control-plane operations NetFluss needs, independent of transport. The
/// real implementation will drive the bundled `defguard-agent` (gRPC); a mock
/// backs UI/flow development and tests until the agent lands.
protocol DefguardControlClient: Sendable {
    /// Enroll this device with a Defguard instance using a URL + enrollment token.
    func enroll(instanceURL: String, token: String, deviceName: String) async throws -> DefguardEnrollmentResult

    /// Begin an MFA session for a location (selects the method to use).
    func startMFA(instance: DefguardInstance, location: DefguardLocation,
                  method: DefguardMFAMethod) async throws -> DefguardMFAChallenge

    /// Complete MFA with a code (TOTP), returning the authorizing pre-shared key.
    func finishMFA(instance: DefguardInstance, location: DefguardLocation,
                   challenge: DefguardMFAChallenge, code: String) async throws -> DefguardMFAResult
}
