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
import Combine

/// Owns enrolled Defguard instances and drives the enrollment + MFA flows for the
/// UI (issue #51). Phase 1: single instance, TOTP only, backed by a mock control
/// client so the whole UX is clickable before the bundled `defguard-agent` lands.
/// Swapping the mock for the real (gRPC) client is a one-line change here.
///
/// The actual WireGuard tunnel bring-up (config + pre-shared key → existing
/// helper path) is intentionally NOT wired yet — it needs the real agent and the
/// WireGuard utun fixes on the VPN branch. Today the flow stops at "authenticated".
@MainActor
final class DefguardManager: ObservableObject {
    static let shared = DefguardManager()

    @Published private(set) var profiles: [DefguardProfile] = []
    @Published private(set) var mfa: MFAState = .idle

    /// State of an in-progress connect/MFA attempt, surfaced to the UI.
    enum MFAState: Equatable {
        case idle
        case enrolling
        case starting(profileID: UUID)
        case awaitingCode(profileID: UUID, method: DefguardMFAMethod)
        case verifying(profileID: UUID)
        /// Phase 1 terminal success: we hold the pre-shared key; tunnel bring-up TBD.
        case authenticated(profileID: UUID)
        case failed(String)
    }

    private let client: DefguardControlClient
    private let store: DefguardProfileStore
    private let credentials: VPNCredentialStore

    /// Carries the active challenge between `startMFA` and the code submission.
    private var pendingChallenge: DefguardMFAChallenge?
    private var pendingLocation: DefguardLocation?

    init(
        client: DefguardControlClient = DefguardMockControlClient(),
        store: DefguardProfileStore = DefguardProfileStore(),
        credentials: VPNCredentialStore = VPNCredentialStore()
    ) {
        self.client = client
        self.store = store
        self.credentials = credentials
        self.profiles = (try? store.load()) ?? []
    }

    // MARK: - Enrollment

    /// Enroll this device with a Defguard instance. Persists the instance + its
    /// locations and stores the device private key in the Keychain.
    @discardableResult
    func enroll(instanceURL: String, token: String, deviceName: String) async -> Result<DefguardProfile, DefguardError> {
        mfa = .enrolling
        do {
            let result = try await client.enroll(instanceURL: instanceURL, token: token, deviceName: deviceName)
            credentials.save(account: result.instance.keychainAccount,
                             username: result.devicePublicKey, password: result.devicePrivateKey)
            let profile = DefguardProfile(instance: result.instance, locations: result.locations)
            profiles.removeAll { $0.instance.instanceURL == profile.instance.instanceURL }
            profiles.append(profile)
            try? store.save(profiles)
            mfa = .idle
            return .success(profile)
        } catch let error as DefguardError {
            mfa = .failed(error.localizedDescription)
            return .failure(error)
        } catch {
            let e = DefguardError.enrollmentFailed(error.localizedDescription)
            mfa = .failed(e.localizedDescription)
            return .failure(e)
        }
    }

    func deleteProfile(_ profile: DefguardProfile) {
        credentials.delete(account: profile.instance.keychainAccount)
        profiles.removeAll { $0.id == profile.id }
        try? store.save(profiles)
    }

    // MARK: - Connect / MFA (Phase 1: stops at "authenticated")

    /// Begin connecting a location. For MFA locations this starts an MFA session
    /// and moves to `.awaitingCode`; the UI then collects a TOTP code and calls
    /// `submitCode`. Non-MFA locations skip straight through (no code needed).
    func connect(_ profile: DefguardProfile, location: DefguardLocation) {
        pendingChallenge = nil
        pendingLocation = location
        guard location.requiresMFA else {
            mfa = .authenticated(profileID: profile.id)   // plain WireGuard: no per-session MFA
            return
        }
        mfa = .starting(profileID: profile.id)
        Task {
            do {
                let challenge = try await client.startMFA(instance: profile.instance, location: location, method: .totp)
                pendingChallenge = challenge
                mfa = .awaitingCode(profileID: profile.id, method: challenge.method)
            } catch {
                mfa = .failed((error as? DefguardError)?.localizedDescription ?? error.localizedDescription)
            }
        }
    }

    /// Submit the TOTP code for the pending MFA session.
    func submitCode(_ code: String, for profile: DefguardProfile) {
        guard let challenge = pendingChallenge, let location = pendingLocation else {
            mfa = .failed("No MFA session in progress.")
            return
        }
        mfa = .verifying(profileID: profile.id)
        Task {
            do {
                let result = try await client.finishMFA(instance: profile.instance, location: location,
                                                        challenge: challenge, code: code)
                // TODO(agent): inject result.presharedKey into the WireGuard config and
                // bring the tunnel up via the existing helper; schedule re-auth at
                // ~result.ttlSeconds. Phase 1 stops here.
                _ = result
                mfa = .authenticated(profileID: profile.id)
            } catch {
                mfa = .failed((error as? DefguardError)?.localizedDescription ?? error.localizedDescription)
            }
        }
    }

    func cancelMFA() {
        pendingChallenge = nil
        pendingLocation = nil
        mfa = .idle
    }
}

// MARK: - Persistence

/// JSON store for enrolled Defguard profiles under Application Support. Secrets
/// (device private key) are NOT stored here — they go to the Keychain.
struct DefguardProfileStore {
    private let fileManager = FileManager.default

    private var baseDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("Netfluss/Defguard", isDirectory: true)
    }

    private var file: URL { baseDirectory.appendingPathComponent("profiles.json") }

    func load() throws -> [DefguardProfile] {
        guard fileManager.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([DefguardProfile].self, from: Data(contentsOf: file))
    }

    func save(_ profiles: [DefguardProfile]) throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(profiles).write(to: file, options: .atomic)
    }
}
