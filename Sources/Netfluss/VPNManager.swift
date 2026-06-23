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
    static let shared = VPNManager()

    @Published private(set) var profiles: [VPNProfile] = []
    @Published private(set) var status: VPNRuntimeStatus = .idle

    /// Set by AppState so the manager can refresh the public IP/flag on
    /// connect/disconnect.
    weak var networkMonitor: NetworkMonitor?

    private let helper: PrivilegedHelperManager
    private let store: VPNProfileStore
    private let credentialStore: VPNCredentialStore
    /// Helper-side handle of the running bundled-binary tunnel (if any).
    private var activeTunnelHandle: String?
    /// Management-interface driver for the active OpenVPN tunnel.
    private var ovpnClient: OpenVPNManagementClient?

    init(
        helper: PrivilegedHelperManager = .shared,
        store: VPNProfileStore = VPNProfileStore(),
        credentialStore: VPNCredentialStore = VPNCredentialStore()
    ) {
        self.helper = helper
        self.store = store
        self.credentialStore = credentialStore
        self.profiles = (try? store.load()) ?? []
    }

    // MARK: - Profile management

    /// Import an OpenVPN config (single `.ovpn`, folder, or `.zip`) into a new
    /// profile. The raw files are copied into the profile's directory and each
    /// `.ovpn` becomes a selectable server. Optional `name` overrides the
    /// suggested name derived from the source.
    @discardableResult
    func importOpenVPNProfile(from source: URL, name: String? = nil) throws -> VPNProfile {
        let result = try VPNConfigImporter.importOpenVPN(from: source)
        let id = UUID()
        try store.writeConfigFiles(result.files, profileID: id)
        let profile = VPNProfile(
            id: id,
            name: name ?? result.suggestedName,
            kind: .openVPN,
            configFileName: result.primaryFileName,
            servers: result.endpoints,
            requiresCredentials: result.requiresCredentials
        )
        profiles.append(profile)
        try store.save(profiles)
        return profile
    }

    func hasStoredCredentials(_ profile: VPNProfile) -> Bool {
        credentialStore.load(account: profile.keychainAccount) != nil
    }

    /// Import a WireGuard config (single `.conf`, folder, or `.zip`) into a new
    /// profile. Each `.conf` becomes a selectable server.
    @discardableResult
    func importWireGuardProfile(from source: URL, name: String? = nil) throws -> VPNProfile {
        let result = try VPNConfigImporter.importWireGuard(from: source)
        let id = UUID()
        try store.writeConfigFiles(result.files, profileID: id)
        let profile = VPNProfile(
            id: id,
            name: name ?? result.suggestedName,
            kind: .wireGuard,
            configFileName: result.primaryFileName,
            servers: result.endpoints,
            requiresCredentials: false
        )
        profiles.append(profile)
        try store.save(profiles)
        return profile
    }

    /// Store (or clear) the username/password for a profile in the Keychain.
    func setCredentials(for profile: VPNProfile, username: String?, password: String?) {
        if username == nil && password == nil {
            credentialStore.delete(account: profile.keychainAccount)
        } else {
            credentialStore.save(account: profile.keychainAccount, username: username, password: password)
        }
    }

    func deleteProfile(_ profile: VPNProfile) {
        if status.profileID == profile.id { disconnect() }
        credentialStore.delete(account: profile.keychainAccount)
        profiles.removeAll { $0.id == profile.id }
        try? store.removeProfileDirectory(profile.id)
        try? store.save(profiles)
    }

    func update(_ profile: VPNProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        try? store.save(profiles)
    }

    func rename(_ profile: VPNProfile, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var p = profiles.first(where: { $0.id == profile.id }), p.name != trimmed else { return }
        p.name = trimmed
        update(p)
    }

    func selectServer(_ index: Int, for profile: VPNProfile) {
        guard var p = profiles.first(where: { $0.id == profile.id }) else { return }
        p.selectedServerIndex = index
        update(p)
    }

    // MARK: - Connection

    func connect(_ profile: VPNProfile, server: VPNServerEndpoint? = nil) {
        guard !status.state.isActive else { return }
        let endpoint = server ?? profile.selectedServer
        status = VPNRuntimeStatus(state: .connecting, profileID: profile.id, serverID: endpoint?.id)

        Task { [weak self] in
            guard let self else { return }
            switch profile.kind {
            case .openVPN, .wireGuard:
                await self.startBundledTunnel(profile, endpoint: endpoint)
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
            self.refreshPublicIP()
        }
    }

    // MARK: - Backends

    private func startBundledTunnel(_ profile: VPNProfile, endpoint: VPNServerEndpoint?) async {
        let configPath = store.configPath(for: profile, endpoint: endpoint)
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
            // WireGuard: wg-quick brought the tunnel up synchronously, so a
            // successful helper reply means we're connected.
            status.state = .connected
            status.connectedSince = Date()
            status.tunnelInterface = result.stdout
            status.assignedIP = wireGuardAddress(for: profile, endpoint: endpoint)
            refreshPublicIP()
            return
        }

        let client = OpenVPNManagementClient(socketPath: socketPath)
        // Capture the store + account (both Sendable) so the provider can read
        // the Keychain from the client's background queue without the MainActor.
        let credentialStore = self.credentialStore
        let account = profile.keychainAccount
        client.credentialsProvider = { _ in
            guard let creds = credentialStore.load(account: account) else { return nil }
            return (username: creds.username, password: creds.password)
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
                refreshPublicIP()
            case "RECONNECTING":
                status.state = .reconnecting
            case "EXITING":
                handleUnexpectedStop()
            default:
                if status.state == .idle { status.state = .connecting }
            }
        case .byteCount(let inBytes, let outBytes):
            status.bytesIn = inBytes
            status.bytesOut = outBytes
        case .needCredentials:
            status.state = .failed("This VPN needs a username and password. Add them in the profile's settings and reconnect.")
        case .authFailed(let message):
            failWithReason(message)
        case .disconnected:
            handleUnexpectedStop()
        case .log:
            break
        }
    }

    /// Refresh the public IP + country flag now and again shortly after, since
    /// routes/DNS can take a moment to settle right after the tunnel comes up
    /// (and to restore the real IP after disconnect).
    private func refreshPublicIP() {
        networkMonitor?.forceRefreshExternalIP()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self?.networkMonitor?.forceRefreshExternalIP()
        }
    }

    /// openvpn stopped on its own (failed to connect, or an established tunnel
    /// dropped). Surface the real reason from its log instead of silently
    /// returning to "Not connected".
    private func handleUnexpectedStop() {
        if case .failed = status.state { return }          // already have a reason
        if status.state == .disconnecting || status.state == .idle {
            status = VPNRuntimeStatus(state: .idle, profileID: status.profileID)
            return
        }
        failWithReason("The VPN connection stopped.")
    }

    /// Set a provisional failure, then refine it with the real reason read from
    /// openvpn's (root-owned) log via the helper.
    private func failWithReason(_ base: String) {
        status.state = .failed(base)
        guard let profileID = status.profileID,
              let profile = profiles.first(where: { $0.id == profileID }) else { return }
        let logPath = Self.managementLogPath(for: profile)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.helper.readVPNLog(path: logPath)
            // Only refine if we're still showing the failure for this attempt.
            guard self.status.profileID == profileID, case .failed = self.status.state else { return }
            if let log = result?.stdout, !log.isEmpty, let summary = Self.summarizeLog(log) {
                self.status.state = .failed(summary)
            }
        }
    }

    /// Pull the most telling line(s) out of an openvpn log tail.
    private static func summarizeLog(_ log: String) -> String? {
        let lines = log.split(whereSeparator: \.isNewline).map(String.init)
        let notable = lines.filter {
            let l = $0.lowercased()
            return l.contains("error") || l.contains("fatal") || l.contains("cannot")
                || l.contains("failed") || l.contains("must define") || l.contains("auth_")
        }
        let chosen = notable.isEmpty ? Array(lines.suffix(1)) : Array(notable.suffix(2))
        // Strip openvpn's leading timestamp for brevity.
        let cleaned = chosen.map { line -> String in
            let parts = line.split(separator: " ", maxSplits: 2)
            return parts.count == 3 && parts[0].allSatisfy({ $0.isNumber || $0 == "-" }) ? String(parts[2]) : line
        }
        let joined = cleaned.joined(separator: " — ")
        return joined.isEmpty ? nil : joined
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
        refreshPublicIP()
    }

    private func nativeServiceName(for profile: VPNProfile) -> String {
        "Netfluss \(profile.name)"
    }

    /// Parse the local [Interface] Address from a WireGuard config for display.
    private func wireGuardAddress(for profile: VPNProfile, endpoint: VPNServerEndpoint?) -> String? {
        let path = store.configPath(for: profile, endpoint: endpoint)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].caseInsensitiveCompare("Address") == .orderedSame else { continue }
            let first = parts[1].split(separator: ",").first.map(String.init) ?? parts[1]
            return first.split(separator: "/").first.map(String.init)
        }
        return nil
    }

    /// Unix socket path for the OpenVPN management interface. Kept short to stay
    /// under the ~104-char sockaddr_un limit.
    private static func managementSocketPath(for profile: VPNProfile) -> String {
        let short = profile.id.uuidString.prefix(8)
        return "/tmp/netfluss-vpn-\(short).sock"
    }

    private static func managementLogPath(for profile: VPNProfile) -> String {
        (managementSocketPath(for: profile) as NSString).deletingPathExtension + ".log"
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

    func writeConfigFiles(_ files: [VPNConfigImporter.ConfigFile], profileID: UUID) throws {
        let dir = profileDirectory(profileID)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            let dest = dir.appendingPathComponent(file.name)
            // file.name may carry subdirectories (folder/zip imports).
            try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: dest, options: .atomic)
        }
    }

    /// Absolute path of the config used to connect: the selected endpoint's own
    /// file, falling back to the profile's primary config.
    func configPath(for profile: VPNProfile, endpoint: VPNServerEndpoint?) -> String {
        let name = endpoint?.configFileName ?? profile.configFileName
        return profileDirectory(profile.id).appendingPathComponent(name).path
    }

    func removeProfileDirectory(_ id: UUID) throws {
        let dir = profileDirectory(id)
        if fileManager.fileExists(atPath: dir.path) { try fileManager.removeItem(at: dir) }
    }
}
