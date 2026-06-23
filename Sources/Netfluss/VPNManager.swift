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

/// Owns the user's VPN profiles and the single active connection. The UI
/// (popover + Preferences) observes `profiles` and `status`.
///
/// Backends per `VPNProtocolKind`:
///   - OpenVPN / WireGuard: the privileged helper launches the bundled binary;
///     live state comes from the binary's control channel (OpenVPN management
///     socket / WireGuard UAPI) — see the marked TODOs for that driver.
///   - IKEv2 / IPsec / L2TP: the macOS-native VPN stack, started/stopped via
///     the helper's `scutil --nc` wrappers.
@MainActor
final class VPNManager: ObservableObject {
    @Published private(set) var profiles: [VPNProfile] = []
    @Published private(set) var status: VPNRuntimeStatus = .idle

    private let helper: PrivilegedHelperManager
    private let store: VPNProfileStore
    /// Helper-side handle of the running bundled-binary tunnel (if any).
    private var activeTunnelHandle: String?
    /// Management-interface driver for the active OpenVPN tunnel.
    private var ovpnClient: OpenVPNManagementClient?

    init(helper: PrivilegedHelperManager = .shared, store: VPNProfileStore = VPNProfileStore()) {
        self.helper = helper
        self.store = store
        self.profiles = (try? store.load()) ?? []
    }

    // MARK: - Profile management

    /// Import a config file into a new profile. The raw config is copied into the
    /// profile's directory; `servers` is the parsed endpoint list (parsing of
    /// .ovpn/.conf/.mobileconfig lives in a dedicated importer — next phase).
    @discardableResult
    func importProfile(
        name: String,
        kind: VPNProtocolKind,
        configSource: URL,
        servers: [VPNServerEndpoint]
    ) throws -> VPNProfile {
        let id = UUID()
        let configName = configSource.lastPathComponent
        try store.copyConfig(from: configSource, profileID: id, named: configName)
        var profile = VPNProfile(id: id, name: name, kind: kind, configFileName: configName, servers: servers)
        profile.selectedServerIndex = 0
        profiles.append(profile)
        try store.save(profiles)
        return profile
    }

    func deleteProfile(_ profile: VPNProfile) {
        if status.profileID == profile.id { disconnect() }
        profiles.removeAll { $0.id == profile.id }
        try? store.removeProfileDirectory(profile.id)
        try? store.save(profiles)
    }

    func update(_ profile: VPNProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        try? store.save(profiles)
    }

    func selectServer(_ index: Int, for profile: VPNProfile) {
        guard var p = profiles.first(where: { $0.id == profile.id }) else { return }
        p.selectedServerIndex = index
        update(p)
    }

    // MARK: - Connection

    func connect(_ profile: VPNProfile, server: VPNServerEndpoint? = nil) {
        guard !status.state.isActive else { return }
        status = VPNRuntimeStatus(state: .connecting, profileID: profile.id, serverID: (server ?? profile.selectedServer)?.id)

        Task { [weak self] in
            guard let self else { return }
            switch profile.kind {
            case .openVPN, .wireGuard:
                await self.startBundledTunnel(profile)
            case .ikev2:
                await self.startNativeTunnel(profile)
            }
        }
    }

    func disconnect() {
        guard status.state.isActive else { return }
        let previous = status
        status.state = .disconnecting

        // Ask openvpn to exit cleanly over the management socket first.
        ovpnClient?.disconnect()

        Task { [weak self] in
            guard let self else { return }
            if let handle = self.activeTunnelHandle {
                // Give the clean shutdown a moment, then ensure the process is gone.
                try? await Task.sleep(nanoseconds: 500_000_000)
                _ = await self.helper.stopVPNTunnel(handle: handle)
                self.activeTunnelHandle = nil
            } else if let profileID = previous.profileID,
                      let profile = self.profiles.first(where: { $0.id == profileID }),
                      profile.kind == .ikev2 {
                _ = await self.helper.disconnectNativeVPN(serviceName: self.nativeServiceName(for: profile))
            }
            self.ovpnClient?.close()
            self.ovpnClient = nil
            self.status = .idle
        }
    }

    // MARK: - Backends

    private func startBundledTunnel(_ profile: VPNProfile) async {
        let configPath = store.configPath(for: profile)
        let socketPath = Self.managementSocketPath(for: profile)

        let result = await helper.startVPNTunnel(
            kind: profile.kind.rawValue,
            configPath: configPath,
            managementSocketPath: socketPath,
            socketOwner: NSUserName()
        )

        guard let result, result.success else {
            status.state = .failed(result?.stderr ?? "Could not start the VPN helper.")
            return
        }
        activeTunnelHandle = result.stdout   // helper returns the handle in stdout

        guard profile.kind == .openVPN else {
            // WireGuard control channel (wg UAPI) is a separate next-phase driver.
            return
        }

        let client = OpenVPNManagementClient(socketPath: socketPath)
        client.credentialsProvider = { kind in
            // TODO (next phase): fetch from Keychain. Cert-only profiles never
            // prompt, so returning nil here still connects those.
            _ = kind
            return nil
        }
        client.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleOpenVPNEvent(event) }
        }
        ovpnClient = client
        client.connect()
    }

    private func handleOpenVPNEvent(_ event: OpenVPNManagementClient.Event) {
        switch event {
        case .state(let state, let assignedIP):
            switch state {
            case "CONNECTED":
                status.state = .connected
                if status.connectedSince == nil { status.connectedSince = Date() }
                if let assignedIP { status.assignedIP = assignedIP }
            case "RECONNECTING":
                status.state = .reconnecting
            case "EXITING":
                status.state = .idle
            default:
                if status.state == .idle { status.state = .connecting }
            }
        case .byteCount(let inBytes, let outBytes):
            status.bytesIn = inBytes
            status.bytesOut = outBytes
        case .needCredentials:
            status.state = .failed("This VPN requires a username and password (credential entry is coming soon).")
        case .authFailed(let message):
            status.state = .failed(message)
        case .disconnected:
            status.state = .idle
        case .log:
            break
        }
    }

    private func startNativeTunnel(_ profile: VPNProfile) async {
        // TODO (next phase): ensure the native service exists (created from the
        // imported .mobileconfig); here we just start it by name.
        let result = await helper.connectNativeVPN(serviceName: nativeServiceName(for: profile))
        guard let result, result.success else {
            status.state = .failed(result?.stderr ?? "Could not start the native VPN.")
            return
        }
        status.state = .connected
        status.connectedSince = Date()
    }

    private func nativeServiceName(for profile: VPNProfile) -> String {
        "Netfluss \(profile.name)"
    }

    /// Unix socket path for the OpenVPN management interface. Kept short to stay
    /// under the ~104-char sockaddr_un limit.
    private static func managementSocketPath(for profile: VPNProfile) -> String {
        let short = profile.id.uuidString.prefix(8)
        return "/tmp/netfluss-vpn-\(short).sock"
    }
}

// MARK: - Persistence

/// On-disk store: profile metadata as JSON plus per-profile config directories
/// under Application Support. Secrets are NOT stored here (Keychain, next phase).
struct VPNProfileStore {
    private let fileManager = FileManager.default

    private var baseDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("Netfluss/VPN", isDirectory: true)
    }

    private var profilesFile: URL { baseDirectory.appendingPathComponent("profiles.json") }

    private func profileDirectory(_ id: UUID) -> URL {
        baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func load() throws -> [VPNProfile] {
        guard fileManager.fileExists(atPath: profilesFile.path) else { return [] }
        let data = try Data(contentsOf: profilesFile)
        return try JSONDecoder().decode([VPNProfile].self, from: data)
    }

    func save(_ profiles: [VPNProfile]) throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: profilesFile, options: .atomic)
    }

    func copyConfig(from source: URL, profileID: UUID, named name: String) throws {
        let dir = profileDirectory(profileID)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        if fileManager.fileExists(atPath: dest.path) { try fileManager.removeItem(at: dest) }
        try fileManager.copyItem(at: source, to: dest)
    }

    func configPath(for profile: VPNProfile) -> String {
        profileDirectory(profile.id).appendingPathComponent(profile.configFileName).path
    }

    func removeProfileDirectory(_ id: UUID) throws {
        let dir = profileDirectory(id)
        if fileManager.fileExists(atPath: dir.path) { try fileManager.removeItem(at: dir) }
    }
}
