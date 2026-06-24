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
import Darwin

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
    /// NEVPNManager-backed IKEv2 controller; `activeIKEv2` gates its status
    /// notifications to the current connection.
    private let ikev2Controller = IKEv2VPNController()
    private var activeIKEv2 = false

    /// Auto-reconnect: when a profile with `options.autoReconnect` drops
    /// unexpectedly, we re-dispatch the connection with exponential backoff
    /// instead of going to a terminal state. `reconnectAttempts` resets on a
    /// successful (re)connect and on a user-initiated connect/disconnect.
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 10
    /// Liveness poll for WireGuard, which has no control-channel drop signal —
    /// we watch the tunnel interface and treat its disappearance as a drop.
    private var wgMonitorTask: Task<Void, Never>?
    /// IKEv2 initial-connect retries. NEVPNManager frequently drops the very
    /// first start right after (re)configuring the tunnel; a retry succeeds. We
    /// retry the initial connect automatically (independent of auto-reconnect),
    /// which is why a manual second attempt "just works".
    private var ikev2InitialRetries = 0
    private static let maxIKEv2InitialRetries = 3
    /// A tunnel up at least this long counts as a real session; a drop sooner is
    /// treated as an initial-connect failure (and auto-retried).
    private static let ikev2StableThreshold: TimeInterval = 20

    init(
        helper: PrivilegedHelperManager = .shared,
        store: VPNProfileStore = VPNProfileStore(),
        credentialStore: VPNCredentialStore = VPNCredentialStore()
    ) {
        self.helper = helper
        self.store = store
        self.credentialStore = credentialStore
        self.profiles = (try? store.load()) ?? []
        ikev2Controller.onStatusChange = { [weak self] status in
            self?.handleIKEv2Status(status)
        }
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

    /// Create an IKEv2 profile managed via NEVPNManager. The username/password are
    /// stored in NetFluss's own Keychain; at connect time the password is read back
    /// and passed directly to the connection (see `startIKEv2`). We do NOT rely on
    /// a `passwordReference` because the macOS IKEv2 EAP path ignores it and would
    /// prompt for the password on every connect.
    @discardableResult
    func addIKEv2Profile(name: String, server: String, remoteID: String, username: String, password: String) -> VPNProfile {
        let profile = VPNProfile(
            name: name,
            kind: .ikev2,
            configFileName: "",
            servers: [],
            requiresCredentials: true,
            ikev2Server: server,
            ikev2RemoteID: remoteID,
            ikev2Username: username
        )
        credentialStore.save(account: profile.keychainAccount, username: username, password: password)
        profiles.append(profile)
        try? store.save(profiles)
        return profile
    }

    /// macOS-native VPN services (IKEv2/IPsec/L2TP) configured in System Settings
    /// or installed from a .mobileconfig.
    func nativeServices() -> [NativeVPN.Service] { NativeVPN.list() }

    /// Create an `.ikev2` profile that controls an existing native VPN service.
    @discardableResult
    func addNativeProfile(service: NativeVPN.Service) -> VPNProfile {
        if let existing = profiles.first(where: { $0.nativeServiceName == service.name }) { return existing }
        let profile = VPNProfile(
            name: service.name,
            kind: .ikev2,
            configFileName: "",
            servers: [],
            nativeServiceName: service.name
        )
        profiles.append(profile)
        try? store.save(profiles)
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

    /// Move a profile one slot up or down. The stored order drives both the
    /// Preferences list and the popover's profile dropdown.
    func moveProfile(_ profile: VPNProfile, up: Bool) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let target = up ? idx - 1 : idx + 1
        guard profiles.indices.contains(target) else { return }
        profiles.swapAt(idx, target)
        try? store.save(profiles)
    }

    /// Reorder profiles from a SwiftUI `onMove` (kept for List-based callers).
    func moveProfiles(fromOffsets source: IndexSet, toOffset destination: Int) {
        profiles.move(fromOffsets: source, toOffset: destination)
        try? store.save(profiles)
    }

    /// Enable/disable automatic reconnection for a profile.
    func setAutoReconnect(_ enabled: Bool, for profile: VPNProfile) {
        guard var p = profiles.first(where: { $0.id == profile.id }),
              p.options.autoReconnect != enabled else { return }
        p.options.autoReconnect = enabled
        update(p)
    }

    /// Enable/disable connect-on-launch. Only one profile can auto-connect (a
    /// single tunnel is active at a time), so enabling it clears the flag on the
    /// others.
    func setConnectOnLaunch(_ enabled: Bool, for profile: VPNProfile) {
        var changed = false
        for i in profiles.indices {
            let want = profiles[i].id == profile.id ? enabled : (enabled ? false : profiles[i].options.connectOnLaunch)
            if profiles[i].options.connectOnLaunch != want {
                profiles[i].options.connectOnLaunch = want
                changed = true
            }
        }
        if changed { try? store.save(profiles) }
    }

    /// Connect the profile marked connect-on-launch, if any. Called once at app
    /// startup. A no-op if a tunnel is already active. Deferred a few seconds so
    /// the network stack / VPN subsystem is ready (an immediate connect at launch
    /// is unreliable, especially for IKEv2).
    func connectOnLaunchIfNeeded() {
        guard !status.state.isActive,
              let profile = profiles.first(where: { $0.options.connectOnLaunch }) else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !self.status.state.isActive,
                  self.profiles.contains(where: { $0.id == profile.id }) else { return }
            self.connect(profile)
        }
    }

    /// Enable/disable applying the profile's own DNS servers while connected.
    func setUseProfileDNS(_ enabled: Bool, for profile: VPNProfile) {
        guard var p = profiles.first(where: { $0.id == profile.id }),
              p.options.useProfileDNS != enabled else { return }
        p.options.useProfileDNS = enabled
        update(p)
    }

    /// Set the DNS preset (by id) applied while connected when useProfileDNS.
    func setProfileDNSPreset(_ presetID: String?, for profile: VPNProfile) {
        guard var p = profiles.first(where: { $0.id == profile.id }) else { return }
        p.options.dnsPresetID = presetID
        update(p)
    }

    // MARK: - Connection

    func connect(_ profile: VPNProfile, server: VPNServerEndpoint? = nil) {
        guard !status.state.isActive else { return }
        cancelPendingReconnect()
        reconnectAttempts = 0
        ikev2InitialRetries = 0
        dispatchConnect(profile, endpoint: server ?? profile.selectedServer, reconnecting: false)
    }

    /// Start the backend for a profile. Shared by the user-facing `connect` and
    /// the auto-reconnect loop; `reconnecting` only affects the displayed state.
    private func dispatchConnect(_ profile: VPNProfile, endpoint: VPNServerEndpoint?, reconnecting: Bool) {
        status = VPNRuntimeStatus(state: reconnecting ? .reconnecting : .connecting,
                                  profileID: profile.id, serverID: endpoint?.id)
        Task { [weak self] in
            guard let self else { return }
            switch profile.kind {
            case .openVPN, .wireGuard:
                await self.startBundledTunnel(profile, endpoint: endpoint)
            case .ikev2:
                if profile.ikev2Server != nil {
                    await self.startIKEv2(profile)        // NEVPNManager
                } else {
                    await self.startNativeTunnel(profile) // legacy scutil service
                }
            }
        }
    }

    func disconnect() {
        guard status.state.isActive else { return }
        // A deliberate disconnect ends any auto-reconnect cycle.
        cancelPendingReconnect()
        stopWireGuardMonitor()
        reconnectAttempts = 0
        ikev2InitialRetries = 0
        networkMonitor?.restoreVPNDNS()
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
                if profile.ikev2Server != nil {
                    self.ikev2Controller.disconnect()   // NEVPNManager; status flows via handleIKEv2Status
                    self.activeIKEv2 = false
                } else if let service = profile.nativeServiceName {
                    NativeVPN.stop(service)
                }
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
            let iface = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            status.state = .connected
            status.connectedSince = Date()
            status.tunnelInterface = iface
            status.assignedIP = wireGuardAddress(for: profile, endpoint: endpoint)
            reconnectAttempts = 0
            startWireGuardMonitor(interface: iface, profileID: profile.id)
            refreshPublicIP()
            applyProfileDNSIfNeeded(profile.id)
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
                reconnectAttempts = 0    // a good connection clears the backoff
                refreshPublicIP()
                applyProfileDNSIfNeeded(status.profileID)
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

    /// Apply the profile's own DNS servers once it's connected (if enabled). The
    /// prior resolver config is restored on disconnect/drop via restoreVPNDNS().
    private func applyProfileDNSIfNeeded(_ profileID: UUID?) {
        guard let profileID,
              let profile = profiles.first(where: { $0.id == profileID }),
              profile.options.useProfileDNS,
              let presetID = profile.options.dnsPresetID,
              let preset = NetworkMonitor.allDNSPresets().first(where: { $0.id == presetID }),
              !preset.servers.isEmpty else { return }
        networkMonitor?.applyVPNDNS(preset.servers)
    }

    /// openvpn stopped on its own (failed to connect, or an established tunnel
    /// dropped). Surface the real reason from its log instead of silently
    /// returning to "Not connected".
    private func handleUnexpectedStop() {
        if case .failed = status.state { return }          // already have a reason
        networkMonitor?.restoreVPNDNS()                    // tunnel DNS is unreachable now
        if status.state == .disconnecting || status.state == .idle {
            status = VPNRuntimeStatus(state: .idle, profileID: status.profileID)
            return
        }
        // Unexpected drop (or a failed reconnect attempt): retry if the profile
        // opted in, otherwise surface the failure.
        if scheduleReconnectIfEnabled(profileID: status.profileID) { return }
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

    private func startIKEv2(_ profile: VPNProfile) async {
        guard let server = profile.ikev2Server,
              let remoteID = profile.ikev2RemoteID,
              let username = profile.ikev2Username else {
            status.state = .failed("This IKEv2 profile is missing its server settings.")
            return
        }
        // Read the password back from our own Keychain and pass it to the
        // connection directly — macOS ignores a stored passwordReference for
        // IKEv2 EAP (it would prompt every connect).
        guard let password = credentialStore.load(account: profile.keychainAccount)?.password,
              !password.isEmpty else {
            status.state = .failed("The VPN password isn't stored — remove the profile and add it again.")
            return
        }
        activeIKEv2 = true
        do {
            try await ikev2Controller.connect(
                name: profile.name, server: server, remoteID: remoteID,
                username: username, password: password
            )
            // Connection progress arrives via handleIKEv2Status.
        } catch {
            activeIKEv2 = false
            status.state = .failed(error.localizedDescription)
        }
    }

    private func handleIKEv2Status(_ status: NEVPNStatus) {
        guard activeIKEv2 else { return }
        switch status {
        case .connecting:
            self.status.state = .connecting
        case .connected:
            self.status.state = .connected
            if self.status.connectedSince == nil { self.status.connectedSince = Date() }
            reconnectAttempts = 0
            // Note: ikev2InitialRetries is NOT reset here — a brief connect that
            // immediately drops shouldn't refill the retry budget (that would
            // loop). It resets on a stable drop and on user connect/disconnect.
            refreshPublicIP()
            applyProfileDNSIfNeeded(self.status.profileID)
        case .reasserting:
            self.status.state = .reconnecting
        case .disconnecting:
            self.status.state = .disconnecting
        case .disconnected, .invalid:
            activeIKEv2 = false
            networkMonitor?.restoreVPNDNS()
            let profileID = self.status.profileID
            let isInvalid = (status == .invalid)
            let serverID = self.status.serverID
            // A tunnel that was only up briefly (or never) is an initial-connect
            // failure, not an established drop — even if it flashed "connected".
            let connectedFor = self.status.connectedSince.map { Date().timeIntervalSince($0) }
            let wasStablyConnected = (connectedFor ?? 0) >= Self.ikev2StableThreshold
            if wasStablyConnected { ikev2InitialRetries = 0 }
            // Surface why it dropped (auth/config/etc.) rather than silently idling.
            ikev2Controller.fetchLastError { [weak self] reason, code in
                guard let self else { return }
                let retryable = !isInvalid && Self.ikev2DropIsRetryable(code)
                // Initial-connect quirk: NEVPNManager often drops the first start(s)
                // right after (re)configuring; a retry succeeds. Retry the initial
                // connect automatically, regardless of the auto-reconnect option,
                // so the user doesn't have to press Connect twice.
                if retryable, !wasStablyConnected,
                   self.ikev2InitialRetries < Self.maxIKEv2InitialRetries,
                   let profileID,
                   let profile = self.profiles.first(where: { $0.id == profileID }),
                   profile.kind == .ikev2, profile.ikev2Server != nil {
                    self.ikev2InitialRetries += 1
                    self.scheduleIKEv2InitialRetry(profile, serverID: serverID)
                    return
                }
                // A stable tunnel dropped, or initial retries ran out — fall back
                // to auto-reconnect if the profile opted in (bounded, with backoff).
                if retryable, self.scheduleReconnectIfEnabled(profileID: profileID) {
                    return
                }
                self.status = VPNRuntimeStatus(state: reason.map { .failed($0) } ?? .idle, profileID: profileID)
                self.refreshPublicIP()
            }
        @unknown default:
            break
        }
    }

    /// Re-attempt an IKEv2 connect after the first start dropped immediately (a
    /// common NEVPNManager quirk). The UI stays in "Connecting…" while waiting so
    /// the retry is invisible to the user.
    private func scheduleIKEv2InitialRetry(_ profile: VPNProfile, serverID: UUID?) {
        cancelPendingReconnect()
        status = VPNRuntimeStatus(state: .connecting, profileID: profile.id, serverID: serverID)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled,
                  self.status.profileID == profile.id, self.status.state == .connecting else { return }
            await self.startIKEv2(profile)
        }
    }

    // MARK: - Auto-reconnect

    /// Schedule a reconnect for the profile if it has auto-reconnect enabled and
    /// we haven't exhausted the attempt budget. Returns true when a reconnect was
    /// scheduled (the caller should then NOT set a terminal state). Sets the
    /// status to `.reconnecting` while waiting.
    private func scheduleReconnectIfEnabled(profileID: UUID?) -> Bool {
        guard let profileID,
              let profile = profiles.first(where: { $0.id == profileID }),
              profile.options.autoReconnect,
              reconnectAttempts < Self.maxReconnectAttempts else { return false }

        let attempt = reconnectAttempts
        reconnectAttempts += 1
        cancelPendingReconnect()
        stopWireGuardMonitor()
        let delay = Self.reconnectDelay(attempt: attempt)
        let serverID = status.serverID
        status = VPNRuntimeStatus(state: .reconnecting, profileID: profileID, serverID: serverID)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Bail if the user disconnected or switched away while we waited.
            guard self.status.profileID == profileID, self.status.state == .reconnecting,
                  let profile = self.profiles.first(where: { $0.id == profileID }) else { return }
            // Clean up any lingering bundled-tunnel process before restarting it
            // (e.g. a WireGuard helper whose interface vanished but didn't exit).
            if profile.kind == .openVPN || profile.kind == .wireGuard {
                if let handle = self.activeTunnelHandle {
                    _ = await self.helper.stopVPNTunnel(handle: handle)
                    self.activeTunnelHandle = nil
                }
                self.ovpnClient?.close()
                self.ovpnClient = nil
            }
            guard self.status.profileID == profileID, self.status.state == .reconnecting else { return }
            let endpoint = profile.servers.first(where: { $0.id == serverID }) ?? profile.selectedServer
            self.dispatchConnect(profile, endpoint: endpoint, reconnecting: true)
        }
        return true
    }

    private func cancelPendingReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// Exponential backoff capped at 30 s: 2, 4, 8, 16, 30, 30, …
    private static func reconnectDelay(attempt: Int) -> Double {
        min(30, 2 * pow(2, Double(attempt)))
    }

    /// Whether an IKEv2 disconnect error code is worth retrying. Auth (8), client
    /// certificate (9/10/11) and configuration (4/13) errors are permanent; the
    /// rest (network/server transients, or no error at all) are retryable.
    private static func ikev2DropIsRetryable(_ code: Int?) -> Bool {
        guard let code else { return true }
        switch code {
        case 4, 8, 9, 10, 11, 13: return false
        default: return true
        }
    }

    // MARK: - WireGuard liveness

    /// WireGuard has no control channel, so poll the tunnel interface; if it
    /// disappears while we think we're connected, treat it as an unexpected drop.
    private func startWireGuardMonitor(interface: String, profileID: UUID) {
        stopWireGuardMonitor()
        guard !interface.isEmpty else { return }
        wgMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.status.profileID == profileID, self.status.state == .connected else { return }
                if !Self.interfaceExists(interface) {
                    self.handleWireGuardDrop()
                    return
                }
            }
        }
    }

    private func stopWireGuardMonitor() {
        wgMonitorTask?.cancel()
        wgMonitorTask = nil
    }

    private func handleWireGuardDrop() {
        if case .failed = status.state { return }
        if status.state == .disconnecting || status.state == .idle { return }
        networkMonitor?.restoreVPNDNS()
        if scheduleReconnectIfEnabled(profileID: status.profileID) { return }
        status.state = .failed("The VPN connection stopped.")
    }

    private static func interfaceExists(_ name: String) -> Bool {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return true }  // on error, don't declare a drop
        defer { freeifaddrs(addrs) }
        var ptr = addrs
        while let cur = ptr {
            if String(cString: cur.pointee.ifa_name) == name { return true }
            ptr = cur.pointee.ifa_next
        }
        return false
    }

    private func startNativeTunnel(_ profile: VPNProfile) async {
        guard let service = profile.nativeServiceName else {
            status.state = .failed("No system VPN service is associated with this profile.")
            return
        }
        guard NativeVPN.start(service) else {
            status.state = .failed("Could not start the system VPN.")
            return
        }
        // Native connect is asynchronous — poll for the Connected state.
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard status.profileID == profile.id, status.state.isActive else { return }
            if NativeVPN.status(service) == "Connected" {
                status.state = .connected
                status.connectedSince = Date()
                refreshPublicIP()
                return
            }
        }
        status.state = .failed("The system VPN did not connect (\(NativeVPN.status(service))).")
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
