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
import NetworkExtension

/// Drives an IKEv2 (username/password / EAP) tunnel through `NEVPNManager`
/// (Personal VPN). This is the only way an app can start an IKEv2 VPN; it
/// requires the `com.apple.developer.networking.vpn.api` ("allow-vpn")
/// entitlement, authorized by a provisioning profile (see Packaging/VPN/README).
///
/// NEVPNManager.shared() is a single configuration, so connecting a profile
/// reconfigures it each time (fine for switching between IKEv2 profiles).
@MainActor
final class IKEv2VPNController {
    /// Delivered on the main actor when the connection status changes.
    var onStatusChange: ((NEVPNStatus) -> Void)?

    private let manager = NEVPNManager.shared()
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let connection = note.object as? NEVPNConnection else { return }
            let status = connection.status
            Task { @MainActor in self?.onStatusChange?(status) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var status: NEVPNStatus { manager.connection.status }

    enum IKEv2Error: LocalizedError {
        case missingPassword
        case step(String, Error)
        var errorDescription: String? {
            switch self {
            case .missingPassword:
                return "The VPN password isn't stored in the Keychain — remove the profile and add it again."
            case .step(let step, let error):
                let ns = error as NSError
                return "IKEv2 \(step) failed: \(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
            }
        }
    }

    /// Configure the Personal VPN from the profile and start it, passing the
    /// EAP username/password directly to *this* connection.
    ///
    /// We deliberately do NOT store a `passwordReference` on the protocol. On
    /// macOS the IKEv2 EAP path does not resolve `passwordReference` — a
    /// long-standing, Apple-confirmed limitation (DTS: "a known limitation with
    /// OSX") — so the VPN agent prompts for the password on every connect no
    /// matter how/where the Keychain item is stored. Instead we hand the
    /// credentials to the connection via `startVPNTunnel(options:)`, which the
    /// agent uses without prompting. This works because the user always starts
    /// the tunnel from NetFluss (not via on-demand, where the app isn't running).
    func connect(
        name: String,
        server: String,
        remoteID: String,
        username: String,
        password: String
    ) async throws {
        guard !password.isEmpty else { throw IKEv2Error.missingPassword }

        do { try await load() } catch { throw IKEv2Error.step("load", error) }

        let proto = NEVPNProtocolIKEv2()
        proto.serverAddress = server
        proto.remoteIdentifier = remoteID
        // Local ID intentionally left unset — providers (e.g. AdGuard) expect it
        // empty for EAP; the username is supplied via EAP, not the IKE identity.
        proto.username = username
        // The server authenticates with its certificate; the user authenticates
        // via EAP (username/password). For this "server cert + EAP" model the IKE
        // authentication method must be .certificate — NOT .none. This matches
        // what macOS System Settings and a .mobileconfig configure
        // (AuthenticationMethod=Certificate + ExtendedAuthEnabled=1); using .none
        // makes the server-side authentication fail with NEVPNConnectionErrorDomain
        // 8. No client certificate/identity is needed because extended (EAP)
        // authentication is enabled — the cert here is the server's, validated by
        // the client. (Local identifier left empty to match the working manual
        // setup, where macOS uses the client IP as the IKE IDi.)
        proto.authenticationMethod = .certificate
        proto.useExtendedAuthentication = true     // username/password (EAP)
        proto.disconnectOnSleep = false
        // No passwordReference — see the method doc. The password is supplied at
        // start time via the options dictionary below.

        manager.protocolConfiguration = proto
        manager.localizedDescription = name
        manager.isEnabled = true

        do { try await save() } catch { throw IKEv2Error.step("save", error) }
        // A save can invalidate the in-memory object — reload before starting.
        do { try await load() } catch { throw IKEv2Error.step("reload", error) }

        let options: [String: NSObject] = [
            NEVPNConnectionStartOptionUsername: username as NSString,
            NEVPNConnectionStartOptionPassword: password as NSString
        ]
        do { try manager.connection.startVPNTunnel(options: options) }
        catch { throw IKEv2Error.step("start", error) }
    }

    func disconnect() {
        manager.connection.stopVPNTunnel()
    }

    /// The reason the tunnel last disconnected (nil message if it was a clean
    /// stop), plus the raw `NSError` code so the caller can tell transient drops
    /// from permanent auth/config failures.
    func fetchLastError(_ completion: @escaping (_ message: String?, _ code: Int?) -> Void) {
        manager.connection.fetchLastDisconnectError { error in
            let ns = error as NSError?
            let message = ns.map { "\($0.localizedDescription) [\($0.domain) \($0.code)]" }
            Task { @MainActor in completion(message, ns?.code) }
        }
    }

    // MARK: - Async wrappers around the callback API

    private func load() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    private func save() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}
