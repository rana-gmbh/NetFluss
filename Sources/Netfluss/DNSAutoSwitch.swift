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

/// "On this network, use this resolver."
///
/// `bssid` pins the rule to one access point. An SSID on its own is a weak
/// key — anyone can name a network after your router, and the rule would then
/// fire on theirs — so the BSSID, which `WifiDetail` already carries, is
/// offered as a tightening rather than a requirement.
struct DNSRule: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var ssid: String
    var bssid: String?
    var presetID: String
    var enabled: Bool

    init(id: String = UUID().uuidString, ssid: String, bssid: String? = nil, presetID: String, enabled: Bool = true) {
        self.id = id
        self.ssid = ssid
        self.bssid = bssid
        self.presetID = presetID
        self.enabled = enabled
    }

    static func load() -> [DNSRule] {
        guard let data = UserDefaults.standard.data(forKey: "dnsRules"),
              let rules = try? JSONDecoder().decode([DNSRule].self, from: data) else {
            return []
        }
        return rules
    }

    static func save(_ rules: [DNSRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: "dnsRules")
    }
}

/// What the engine decided, for the UI to explain itself.
enum DNSAutoSwitchState: Equatable, Sendable {
    case off
    /// No helper, so the only way to set DNS would be an authentication prompt
    /// on every network change.
    case needsHelper
    /// A VPN profile's DNS override owns the resolver right now.
    case suspendedByVPN
    /// On a network with a rule, but holding at DHCP until the captive portal
    /// is cleared — applying early is what breaks the login page.
    case waitingForPortal(ssid: String)
    /// On a network with a rule, but the link is down. Kept apart from
    /// `.noRule` so a matched rule never reads as "no rule applies".
    case waitingForNetwork(ssid: String)
    case applied(ssid: String, presetID: String)
    case noRule
    /// The rule wants an encrypted preset, but this build can't configure
    /// encrypted DNS, or the user declined macOS's prompt for it.
    case encryptedDNSUnavailable(presetID: String)
    /// The encrypted preset is configured; the user still has to switch it on
    /// in System Settings. Saving it again would change nothing.
    case waitingForEncryptedDNS(presetID: String)
    /// The user picked a resolver by hand on this network; the rules stay out
    /// of it until another network is joined. Empty name = wired.
    case manualOverride(ssid: String)
}

/// Decides which DNS preset the current network should be using.
///
/// Pure apart from the debounce clock: everything it needs is passed in, so
/// the decision table can be exercised without touching system DNS.
@MainActor
final class DNSRuleEngine {
    private enum Constants {
        /// Let routes, DHCP and the portal check settle before writing DNS.
        static let settleDelay: TimeInterval = 2
        /// A write that didn't take is retried on a growing delay. Every attempt
        /// is a privileged call, and a resolver change flushes the system's DNS
        /// cache, so a failure must not repeat on every tick.
        static let firstRetryDelay: TimeInterval = 5
        static let maxRetryDelay: TimeInterval = 300
    }

    struct Input: Sendable {
        var enabled: Bool
        var helperEnabled: Bool
        var ssid: String?
        var bssid: String?
        var linkHealth: LinkHealth?
        /// Whether the portal check can be trusted. With the internet check off
        /// there is no portal signal, so the engine cannot wait for one.
        var portalSignalAvailable: Bool
        var vpnDNSActive: Bool
        var activePresetID: String?
        /// The live per-service resolver, or nil until it has been read.
        var currentServers: [String]?
        /// What every known preset points at, by id — hidden ones included,
        /// since a rule may name a preset that isn't shown in the popover.
        var presetTargets: [String: DNSResolverTarget]
        /// NetFluss's system encrypted-DNS configuration.
        var encrypted: EncryptedDNSStatus = .notInstalled
        /// The last encrypted-DNS save was refused; don't prompt again.
        var encryptedRefused: Bool = false
        var rules: [DNSRule]
        var fallbackPresetID: String?
        /// The network (SSID, "" for wired) on which the user last picked a
        /// resolver by hand, if any.
        var manualOverrideNetwork: String? = nil
    }

    enum Decision: Equatable, Sendable {
        case doNothing(DNSAutoSwitchState)
        case apply(presetID: String, state: DNSAutoSwitchState)
        /// Stop NetFluss's encrypted DNS applying, without touching anything else.
        case pauseEncrypted(state: DNSAutoSwitchState)
    }

    enum Action: Equatable, Sendable {
        case apply(presetID: String)
        case pauseEncrypted
    }

    private(set) var state: DNSAutoSwitchState = .off
    private var lastNetworkKey: String?
    private var pendingSince: Date?
    private var lastAttempt: (presetID: String, at: Date, count: Int)?

    var onChange: ((DNSAutoSwitchState) -> Void)?

    func reset() {
        lastNetworkKey = nil
        pendingSince = nil
        lastAttempt = nil
    }

    /// The decision table. Order is the whole design: each guard explains why
    /// the engine must not write DNS in that situation.
    nonisolated static func decide(_ input: Input) -> Decision {
        guard input.enabled else { return .doNothing(.off) }

        // A VPN profile's DNS override stashes the prior servers so it can put
        // them back. Writing underneath it would make that backup restore our
        // value as if it were the user's own.
        guard !input.vpnDNSActive else { return .doNothing(.suspendedByVPN) }

        // A hand pick in the popover is a decision about this network; undoing
        // it two seconds later made the switcher look broken.
        let networkName = input.ssid ?? ""
        if let manual = input.manualOverrideNetwork, manual == networkName {
            return .doNothing(.manualOverride(ssid: networkName))
        }

        guard let ssid = input.ssid, !ssid.isEmpty else {
            // Wired, or no association: only the catch-all can apply.
            guard let fallback = input.fallbackPresetID else { return .doNothing(.noRule) }
            return write(fallback, ssid: "", input)
        }

        guard let target = match(ssid: ssid, bssid: input.bssid, rules: input.rules)
            ?? input.fallbackPresetID else {
            return .doNothing(.noRule)
        }

        // Captive portals answer DNS themselves; handing the machine a public
        // resolver before the login page is cleared is how you end up online
        // with nothing working. An encrypted resolver can't reach the portal at
        // all, so one left on from the last network is switched off meanwhile.
        if input.portalSignalAvailable, input.linkHealth == .limited {
            if input.encrypted.isActive { return .pauseEncrypted(state: .waitingForPortal(ssid: ssid)) }
            return .doNothing(.waitingForPortal(ssid: ssid))
        }
        if input.linkHealth == .offline {
            return .doNothing(.waitingForNetwork(ssid: ssid))
        }

        return write(target, ssid: ssid, input)
    }

    /// The tail every matched rule shares: skip what is already in effect, then
    /// check that this kind of write is possible at all.
    private nonisolated static func write(_ presetID: String, ssid: String, _ input: Input) -> Decision {
        let applied = DNSAutoSwitchState.applied(ssid: ssid, presetID: presetID)

        // Already right: never spend a privileged call confirming it.
        if isApplied(presetID, input) { return .doNothing(applied) }

        if case .encrypted(let transport, let servers)? = input.presetTargets[presetID] {
            switch input.encrypted {
            case .unknown, .unavailable:
                return .doNothing(.encryptedDNSUnavailable(presetID: presetID))
            default:
                break
            }
            // Saved but not switched on: writing it again would change nothing,
            // and the user has to act in System Settings anyway.
            if let pending = input.encrypted.awaitingUser,
               pending.transport == transport, pending.servers == servers {
                return .doNothing(.waitingForEncryptedDNS(presetID: presetID))
            }
            // A refused save means macOS asked and the user said no; asking on
            // every network change would be nagging.
            if input.encryptedRefused { return .doNothing(.encryptedDNSUnavailable(presetID: presetID)) }
            return .apply(presetID: presetID, state: applied)
        }

        // Without the helper every server write goes through `osascript … with
        // administrator privileges`, which means a password prompt on every
        // network change. Refuse rather than degrade into that. Switching off
        // encrypted DNS on top of servers that are already right needs no helper.
        let serversAlreadyRight: Bool = {
            guard case .plain(let servers)? = input.presetTargets[presetID] else { return false }
            return input.currentServers == servers
        }()
        guard input.helperEnabled || serversAlreadyRight else { return .doNothing(.needsHelper) }

        return .apply(presetID: presetID, state: applied)
    }

    /// Whether the live resolver already is this preset. Compared by target as
    /// well as by id: `activePresetID` is the first preset matching the live
    /// resolver, so a custom preset with the same servers as a built-in would
    /// otherwise never count as applied and be rewritten for ever.
    private nonisolated static func isApplied(_ presetID: String, _ input: Input) -> Bool {
        if presetID == input.activePresetID { return true }
        switch input.presetTargets[presetID] {
        case .plain(let servers)?:
            // Encrypted DNS overrides the servers while it is on.
            guard !input.encrypted.isActive, let current = input.currentServers else { return false }
            return current == servers
        case .encrypted(let transport, let servers)?:
            return input.encrypted.activeTarget == .encrypted(transport, servers: servers)
        case nil:
            return false
        }
    }

    /// Most specific first: this access point, then this network name.
    nonisolated static func match(ssid: String, bssid: String?, rules: [DNSRule]) -> String? {
        let active = rules.filter { $0.enabled && $0.ssid == ssid }
        if let bssid, !bssid.isEmpty,
           let pinned = active.first(where: { ($0.bssid ?? "").caseInsensitiveCompare(bssid) == .orderedSame }) {
            return pinned.presetID
        }
        return active.first(where: { ($0.bssid ?? "").isEmpty })?.presetID
    }

    /// Run the table and apply the debounce. Returns the write to make, if any.
    func evaluate(_ input: Input, now: Date = Date()) -> Action? {
        let decision = Self.decide(input)
        let key = "\(input.ssid ?? "")|\(input.bssid ?? "")"
        if key != lastNetworkKey {
            lastNetworkKey = key
            pendingSince = now
            lastAttempt = nil
        }

        switch decision {
        case .doNothing(let newState):
            if case .applied = newState { lastAttempt = nil }
            publish(newState)
            return nil
        case .apply(let presetID, let newState):
            return debounced(key: presetID, state: newState, now: now) ? .apply(presetID: presetID) : nil
        case .pauseEncrypted(let newState):
            return debounced(key: Self.pauseKey, state: newState, now: now) ? .pauseEncrypted : nil
        }
    }

    private static let pauseKey = "\u{0}pause-encrypted"

    /// Networks arrive in pieces — association, address, route — and writing
    /// DNS into the middle of that is how you get a write per tick. Wait for it
    /// to settle, then back off a write that doesn't take.
    private func debounced(key: String, state newState: DNSAutoSwitchState, now: Date) -> Bool {
        guard let pendingSince, now.timeIntervalSince(pendingSince) >= Constants.settleDelay else {
            return false
        }
        let attempts = lastAttempt?.presetID == key ? lastAttempt?.count ?? 0 : 0
        if attempts > 0, let lastAttempt,
           now.timeIntervalSince(lastAttempt.at) < Self.retryDelay(afterAttempts: attempts) {
            return false
        }
        lastAttempt = (key, now, attempts + 1)
        publish(newState)
        return true
    }

    /// 5, 10, 20 … seconds, up to five minutes.
    nonisolated static func retryDelay(afterAttempts attempts: Int) -> TimeInterval {
        min(Constants.maxRetryDelay, Constants.firstRetryDelay * pow(2, Double(attempts - 1)))
    }

    private func publish(_ newState: DNSAutoSwitchState) {
        guard newState != state else { return }
        state = newState
        onChange?(newState)
    }
}
