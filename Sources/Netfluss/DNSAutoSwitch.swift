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
    case applied(ssid: String, presetID: String)
    case noRule
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
        var rules: [DNSRule]
        var fallbackPresetID: String?
    }

    enum Decision: Equatable, Sendable {
        case doNothing(DNSAutoSwitchState)
        case apply(presetID: String, state: DNSAutoSwitchState)
    }

    private(set) var state: DNSAutoSwitchState = .off
    private var lastNetworkKey: String?
    private var pendingSince: Date?

    var onChange: ((DNSAutoSwitchState) -> Void)?

    func reset() {
        lastNetworkKey = nil
        pendingSince = nil
    }

    /// The decision table. Order is the whole design: each guard explains why
    /// the engine must not write DNS in that situation.
    nonisolated static func decide(_ input: Input) -> Decision {
        guard input.enabled else { return .doNothing(.off) }

        // Without the helper every write goes through `osascript … with
        // administrator privileges`, which means a password prompt on every
        // network change. Refuse rather than degrade into that.
        guard input.helperEnabled else { return .doNothing(.needsHelper) }

        // A VPN profile's DNS override stashes the prior servers so it can put
        // them back. Writing underneath it would make that backup restore our
        // value as if it were the user's own.
        guard !input.vpnDNSActive else { return .doNothing(.suspendedByVPN) }

        guard let ssid = input.ssid, !ssid.isEmpty else {
            // Wired, or no association: only the catch-all can apply.
            guard let fallback = input.fallbackPresetID else { return .doNothing(.noRule) }
            if fallback == input.activePresetID { return .doNothing(.applied(ssid: "", presetID: fallback)) }
            return .apply(presetID: fallback, state: .applied(ssid: "", presetID: fallback))
        }

        guard let target = match(ssid: ssid, bssid: input.bssid, rules: input.rules)
            ?? input.fallbackPresetID else {
            return .doNothing(.noRule)
        }

        // Captive portals answer DNS themselves; handing the machine a public
        // resolver before the login page is cleared is how you end up online
        // with nothing working.
        if input.portalSignalAvailable, input.linkHealth == .limited {
            return .doNothing(.waitingForPortal(ssid: ssid))
        }
        if input.linkHealth == .offline {
            return .doNothing(.noRule)
        }

        // Already right: never spend a privileged call confirming it.
        if target == input.activePresetID {
            return .doNothing(.applied(ssid: ssid, presetID: target))
        }

        return .apply(presetID: target, state: .applied(ssid: ssid, presetID: target))
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

    /// Run the table and apply the debounce. Returns the preset to apply, if any.
    func evaluate(_ input: Input, now: Date = Date()) -> String? {
        let decision = Self.decide(input)
        let key = "\(input.ssid ?? "")|\(input.bssid ?? "")"
        if key != lastNetworkKey {
            lastNetworkKey = key
            pendingSince = now
        }

        switch decision {
        case .doNothing(let newState):
            publish(newState)
            return nil
        case .apply(let presetID, let newState):
            // Networks arrive in pieces — association, address, route — and
            // writing DNS into the middle of that is how you get a write per
            // tick. Wait for it to settle.
            guard let pendingSince, now.timeIntervalSince(pendingSince) >= Constants.settleDelay else {
                return nil
            }
            publish(newState)
            return presetID
        }
    }

    private func publish(_ newState: DNSAutoSwitchState) {
        guard newState != state else { return }
        state = newState
        onChange?(newState)
    }
}
