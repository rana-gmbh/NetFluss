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

    /// Configure the Personal VPN from the profile and start it. `passwordRef` is
    /// a persistent Keychain reference to the password item.
    func connect(
        name: String,
        server: String,
        remoteID: String,
        username: String,
        passwordRef: Data?
    ) async throws {
        try await load()

        let proto = NEVPNProtocolIKEv2()
        proto.serverAddress = server
        proto.remoteIdentifier = remoteID
        proto.localIdentifier = username
        proto.username = username
        proto.passwordReference = passwordRef
        proto.authenticationMethod = .none        // server cert + EAP user auth
        proto.useExtendedAuthentication = true     // username/password (EAP)
        proto.disconnectOnSleep = false

        manager.protocolConfiguration = proto
        manager.localizedDescription = name
        manager.isEnabled = true

        try await save()
        // A save can invalidate the in-memory object — reload before starting.
        try await load()
        try manager.connection.startVPNTunnel()
    }

    func disconnect() {
        manager.connection.stopVPNTunnel()
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
