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

// MARK: - Protocol kind

/// The VPN technologies NetFluss can manage. OpenVPN and WireGuard are driven by
/// bundled CLI binaries via the privileged helper; IKEv2/IPsec/L2TP use the
/// macOS-native VPN stack configured through a `.mobileconfig` profile.
enum VPNProtocolKind: String, Codable, Sendable, CaseIterable {
    case openVPN
    case wireGuard
    case ikev2

    var displayName: String {
        switch self {
        case .openVPN: return "OpenVPN"
        case .wireGuard: return "WireGuard"
        case .ikev2: return "IKEv2 / IPsec"
        }
    }

    /// Whether connections of this kind are run by a bundled binary through the
    /// privileged helper (vs. the OS-native VPN stack).
    var usesBundledBinary: Bool {
        switch self {
        case .openVPN, .wireGuard: return true
        case .ikev2: return false
        }
    }
}

// MARK: - Server endpoint

/// One selectable server within a profile. Provider "router" bundles often ship
/// many `.ovpn`/`remote` entries; each becomes an endpoint the user can pick.
struct VPNServerEndpoint: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    /// User-facing label, e.g. "Zurich TCP" or the source filename.
    var label: String
    var host: String
    var port: Int?
    /// Transport hint where relevant (e.g. "udp"/"tcp" for OpenVPN).
    var transport: String?
    /// Config file (within the profile directory) this endpoint connects with.
    /// Provider bundles ship one `.ovpn` per server, so each endpoint usually
    /// references its own file; nil falls back to the profile's primary config.
    var configFileName: String?

    init(id: UUID = UUID(), label: String, host: String, port: Int? = nil, transport: String? = nil, configFileName: String? = nil) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.transport = transport
        self.configFileName = configFileName
    }
}

// MARK: - Per-profile options

struct VPNProfileOptions: Codable, Equatable, Sendable {
    /// Reconnect automatically if the tunnel drops.
    var autoReconnect: Bool = false
    /// Block other traffic while connected if the tunnel goes down.
    var killSwitch: Bool = false
    /// Apply the profile's own DNS servers while connected (reuses the existing
    /// DNS-via-helper machinery).
    var useProfileDNS: Bool = false
    var dnsServers: [String] = []
    /// Connect this profile automatically when NetFluss launches.
    var connectOnLaunch: Bool = false

    init() {}
}

// MARK: - Profile

/// A persisted VPN configuration. Secrets are NOT stored here — only a Keychain
/// account reference. The raw config lives on disk under the app's VPN support
/// directory, referenced by `configFileName`.
struct VPNProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var kind: VPNProtocolKind
    /// Filename (relative to the profile's directory) of the imported config.
    var configFileName: String
    var servers: [VPNServerEndpoint]
    /// Index into `servers` of the user's current selection.
    var selectedServerIndex: Int
    /// Whether connecting prompts for a username/password (OpenVPN
    /// `auth-user-pass`). Cert-only profiles are `false`.
    var requiresCredentials: Bool
    /// Keychain account used to store this profile's credentials (if any).
    var keychainAccount: String
    var options: VPNProfileOptions
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        kind: VPNProtocolKind,
        configFileName: String,
        servers: [VPNServerEndpoint] = [],
        selectedServerIndex: Int = 0,
        requiresCredentials: Bool = false,
        keychainAccount: String? = nil,
        options: VPNProfileOptions = VPNProfileOptions(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.configFileName = configFileName
        self.servers = servers
        self.selectedServerIndex = selectedServerIndex
        self.requiresCredentials = requiresCredentials
        self.keychainAccount = keychainAccount ?? "vpn.\(id.uuidString)"
        self.options = options
        self.createdAt = createdAt
    }

    var selectedServer: VPNServerEndpoint? {
        guard servers.indices.contains(selectedServerIndex) else { return servers.first }
        return servers[selectedServerIndex]
    }
}

// MARK: - Runtime status

/// Live connection state for the active profile. Published by `VPNManager` and
/// observed by the popover / preferences UI.
enum VPNConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting
    case disconnecting
    case failed(String)

    var isBusy: Bool { self == .connecting || self == .reconnecting || self == .disconnecting }
    var isActive: Bool { self == .connected || self == .connecting || self == .reconnecting }
}

struct VPNRuntimeStatus: Equatable, Sendable {
    var state: VPNConnectionState = .idle
    var profileID: UUID?
    var serverID: UUID?
    var connectedSince: Date?
    var assignedIP: String?
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    /// BSD name of the tunnel interface (e.g. "utun4") once established.
    var tunnelInterface: String?

    static let idle = VPNRuntimeStatus()
}
