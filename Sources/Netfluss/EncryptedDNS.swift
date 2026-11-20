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

import AppKit
import Foundation
import NetworkExtension
import Security

// MARK: - Validation

/// Checks what people type into a custom DNS entry. Everything here ends up in
/// a system-wide resolver configuration, so it is held to the formats the
/// system expects rather than "whatever parses".
enum DNSEntryValidator {
    /// A literal IPv4 or IPv6 address — not a hostname, not a CIDR.
    static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    /// An `https://host[:port]/path` URL, normalised, or nil. No credentials, no
    /// query or fragment: a DoH endpoint is a host and a path.
    static func normalizedDoHURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, isValidHostname(host) || isIPAddress(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.url != nil else {
            return nil
        }
        return trimmed
    }

    /// A DNS name usable as a DoT server name (it is checked against the
    /// server's TLS certificate, so it has to be a real hostname).
    static func isValidServerName(_ raw: String) -> Bool {
        isValidHostname(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isValidHostname(_ name: String) -> Bool {
        let host = name.hasSuffix(".") ? String(name.dropLast()) : name
        guard !host.isEmpty, host.utf8.count <= 253, !isIPAddress(host) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        // A bare single label ("router") can't carry a public certificate.
        guard labels.count >= 2 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63
                && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    /// Whether a preset can be handed to the system as it stands.
    static func isValid(_ preset: DNSPreset) -> Bool {
        guard preset.servers.allSatisfy(isIPAddress) else { return false }
        switch preset.transport {
        case nil:
            return true
        case .https(let url):
            return normalizedDoHURL(url) != nil
        case .tls(let serverName):
            // The resolver connects to these addresses and checks the name
            // against their certificate; without one there is nothing to dial.
            return isValidServerName(serverName) && !preset.servers.isEmpty
        }
    }
}

// MARK: - State

/// NetFluss's encrypted-DNS configuration as macOS holds it.
struct EncryptedDNSConfig: Equatable, Sendable {
    var transport: DNSTransport
    var servers: [String]
    /// Saved but limited to a reserved dummy domain (`pauseMatchDomain`), so it
    /// answers nothing real and every query goes to the plain servers. This is
    /// how NetFluss switches back to plain DNS without removing the
    /// configuration — removing it would throw away the user's approval and the
    /// switch they turned on in System Settings.
    ///
    /// Not an on-demand Disconnect rule: macOS only evaluates those when a
    /// connection starts, so a running configuration kept answering over DoH
    /// (seen on macOS 27.2.1).
    var paused: Bool

    var target: DNSResolverTarget { .encrypted(transport, servers: servers) }
}

enum EncryptedDNSStatus: Equatable, Sendable {
    /// Not read yet.
    case unknown
    /// This build can't configure encrypted DNS: it isn't signed with the
    /// `dns-settings` entitlement (a raw `swift build` binary, or a release
    /// signed without the profile), or the system refused to load the config.
    case unavailable
    case notInstalled
    /// `enabled` is the user's switch in System Settings; apps can't set it.
    case installed(EncryptedDNSConfig, enabled: Bool)

    /// The encrypted resolver actually answering queries right now.
    var activeTarget: DNSResolverTarget? {
        guard case .installed(let config, let enabled) = self, enabled, !config.paused else { return nil }
        return config.target
    }

    var isActive: Bool { activeTarget != nil }

    /// Saved, not paused, but not switched on by the user yet.
    var awaitingUser: EncryptedDNSConfig? {
        guard case .installed(let config, let enabled) = self, !enabled, !config.paused else { return nil }
        return config
    }

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    var isPausable: Bool {
        guard case .installed(let config, _) = self else { return false }
        return !config.paused
    }
}

// MARK: - Matching

enum DNSPresetMatcher {
    /// The preset in effect. While NetFluss's encrypted configuration is active
    /// it wins — it overrides the per-service servers — and only presets with the
    /// same transport can match it. Otherwise only plain presets can match the
    /// servers: an encrypted preset's bootstrap IPs say nothing about whether the
    /// system is encrypting.
    ///
    /// `presets` is in display order with hidden presets last, so a visible
    /// preset wins a tie with a hidden one.
    static func activePresetID(
        servers: [String]?,
        encrypted: EncryptedDNSStatus,
        presets: [DNSPreset]
    ) -> String? {
        if case .encrypted(let transport, let bootstrap)? = encrypted.activeTarget {
            let candidates = presets.filter { $0.transport == transport }
            return (candidates.first { $0.servers == bootstrap } ?? candidates.first)?.id
        }
        guard let servers else { return nil }
        return presets.first { $0.transport == nil && $0.servers == servers }?.id
    }
}

// MARK: - System store

/// The slice of `NEDNSSettingsManager` NetFluss uses, so the controller can be
/// exercised without touching the system configuration.
@MainActor
protocol EncryptedDNSStore: AnyObject {
    /// nil config = nothing installed.
    func load() async throws -> (config: EncryptedDNSConfig?, enabled: Bool)
    func save(_ config: EncryptedDNSConfig, description: String) async throws
    func remove() async throws
}

@MainActor
final class SystemEncryptedDNSStore: EncryptedDNSStore {
    private var manager: NEDNSSettingsManager { NEDNSSettingsManager.shared() }

    func load() async throws -> (config: EncryptedDNSConfig?, enabled: Bool) {
        try await manager.loadFromPreferences()
        return (Self.config(from: manager), manager.isEnabled)
    }

    func save(_ config: EncryptedDNSConfig, description: String) async throws {
        // Saving over a stale copy fails with `configurationStale`.
        try await manager.loadFromPreferences()
        let settings: NEDNSSettings
        switch config.transport {
        case .https(let url):
            let doh = NEDNSOverHTTPSSettings(servers: config.servers)
            doh.serverURL = URL(string: url)
            settings = doh
        case .tls(let serverName):
            let dot = NEDNSOverTLSSettings(servers: config.servers)
            dot.serverName = serverName
            settings = dot
        }
        if config.paused {
            settings.matchDomains = [Self.pauseMatchDomain]
            // Keep the dummy domain out of the search list, or every short
            // name would also be tried as `name.paused.netfluss.invalid`.
            settings.matchDomainsNoSearch = true
        }
        manager.dnsSettings = settings
        manager.localizedDescription = description
        manager.onDemandRules = nil
        try await manager.saveToPreferences()
    }

    func remove() async throws {
        try await manager.loadFromPreferences()
        try await manager.removeFromPreferences()
    }

    /// `.invalid` is reserved (RFC 2606): nothing real ever lives under it.
    static let pauseMatchDomain = "paused.netfluss.invalid"

    private static func config(from manager: NEDNSSettingsManager) -> EncryptedDNSConfig? {
        let transport: DNSTransport
        switch manager.dnsSettings {
        case let doh as NEDNSOverHTTPSSettings:
            guard let url = doh.serverURL?.absoluteString else { return nil }
            transport = .https(url: url)
        case let dot as NEDNSOverTLSSettings:
            guard let name = dot.serverName else { return nil }
            transport = .tls(serverName: name)
        default:
            return nil
        }
        let paused = manager.dnsSettings?.matchDomains == [pauseMatchDomain]
        return EncryptedDNSConfig(transport: transport, servers: manager.dnsSettings?.servers ?? [], paused: paused)
    }
}

// MARK: - Controller

/// Owns NetFluss's one system encrypted-DNS configuration.
///
/// None of this needs the privileged helper: the configuration is per app and
/// macOS asks the user itself — once to allow it, then they switch it on in
/// System Settings. Apps cannot switch it on, so the controller only ever
/// writes the configuration and reports whether the user has done their part.
@MainActor
final class EncryptedDNSController {
    private enum Constants {
        static let refreshInterval: TimeInterval = 15
    }

    private(set) var status: EncryptedDNSStatus = .unknown
    /// The last save failed — most often the user answered "Don't Allow". Kept
    /// so the rule engine doesn't save again and put the prompt back up on
    /// every network change. Cleared by the next explicit choice in the UI.
    private(set) var saveRefused = false
    var onChange: (() -> Void)?

    private let store: EncryptedDNSStore
    private var lastRefresh: Date?
    private var observer: NSObjectProtocol?

    private let hasEntitlement: Bool

    init(store: EncryptedDNSStore, hasEntitlement: Bool = true) {
        self.store = store
        self.hasEntitlement = hasEntitlement
    }

    convenience init() {
        self.init(store: SystemEncryptedDNSStore(), hasEntitlement: Self.processHasDNSSettingsEntitlement())
    }

    /// Whether this process is signed with
    /// `com.apple.developer.networking.networkextension` → `dns-settings`.
    nonisolated static func processHasDNSSettingsEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.networking.networkextension" as CFString, nil
              ) else { return false }
        return (value as? [String])?.contains("dns-settings") ?? false
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NEDNSSettingsConfigurationDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    /// The switch in System Settings posts no notification to the app on every
    /// macOS version, so the status is also re-read on the DNS refresh cadence.
    func refreshIfStale(now: Date = Date()) {
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < Constants.refreshInterval { return }
        lastRefresh = now
        Task { await refresh() }
    }

    func refresh() async {
        lastRefresh = Date()
        // Without the entitlement `loadFromPreferences` still succeeds — it just
        // reads back nothing — so it can't tell a raw build from a fresh install.
        guard hasEntitlement else {
            publish(.unavailable)
            return
        }
        let newStatus: EncryptedDNSStatus
        do {
            let loaded = try await store.load()
            if let config = loaded.config {
                newStatus = .installed(config, enabled: loaded.enabled)
            } else {
                newStatus = .notInstalled
            }
        } catch {
            newStatus = .unavailable
        }
        publish(newStatus)
    }

    /// Point the configuration at this preset and un-pause it. The first time,
    /// macOS asks whether to allow it.
    func activate(_ preset: DNSPreset, userInitiated: Bool) async -> Error? {
        guard let transport = preset.transport else { return nil }
        if userInitiated { saveRefused = false }
        guard !saveRefused else { return nil }
        let config = EncryptedDNSConfig(transport: transport, servers: preset.servers, paused: false)
        return await save(config, description: "NetFluss – \(preset.name)")
    }

    /// Keep the configuration but stop it applying.
    func pause() async -> Error? {
        guard case .installed(var config, _) = status, !config.paused else { return nil }
        config.paused = true
        return await save(config, description: "NetFluss")
    }

    /// Undo `pause()` with whatever provider was configured.
    func resume() async -> Error? {
        guard case .installed(var config, _) = status, config.paused else { return nil }
        config.paused = false
        return await save(config, description: "NetFluss")
    }

    func remove() async -> Error? {
        saveRefused = false
        do {
            try await store.remove()
        } catch {
            await refresh()
            return error
        }
        await refresh()
        return nil
    }

    private func save(_ config: EncryptedDNSConfig, description: String) async -> Error? {
        do {
            try await store.save(config, description: description)
            saveRefused = false
        } catch {
            saveRefused = true
            await refresh()
            onChange?()
            return error
        }
        await refresh()
        return nil
    }

    private func publish(_ newStatus: EncryptedDNSStatus) {
        let changed = newStatus != status
        status = newStatus
        if changed { onChange?() }
    }

    /// Where the user switches the configuration on. "VPN & Filters" is the
    /// Network pane's sidebar entry from macOS 13 through 27 ("Filters &
    /// Proxies" is only a heading inside it).
    static var settingsPath: String {
        L10n.text("System Settings › Network › VPN & Filters")
    }

    /// Opens System Settings › Network, one click from VPN & Filters. No URL
    /// anchor reaches that entry itself, and the Network Extension settings
    /// extension opens the top-level VPN pane instead — the wrong place.
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
