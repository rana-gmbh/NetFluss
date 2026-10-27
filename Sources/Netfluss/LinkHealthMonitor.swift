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

/// Which physical medium currently carries the default route. Picks the glyph.
enum LinkMedium: String, Equatable, Sendable {
    case wifi
    case ethernet
    case other
}

/// Traffic-light state for the menu bar link indicator.
enum LinkHealth: String, Equatable, Sendable {
    /// Associated, addressed, and the internet answered.
    case online
    /// Associated but going nowhere: no address, no gateway, or a captive
    /// portal / dead upstream.
    case limited
    /// No usable interface at all.
    case offline
}

struct LinkStatus: Equatable, Sendable {
    let health: LinkHealth
    let medium: LinkMedium
    /// BSD name of the interface the glyph describes, for the tooltip.
    let interfaceName: String
    /// SSID when the medium is Wi-Fi, for the tooltip.
    let ssid: String?

    static let offline = LinkStatus(health: .offline, medium: .other, interfaceName: "", ssid: nil)
}

/// Result of one reachability probe.
enum LinkProbeOutcome: Equatable, Sendable {
    /// The expected body came back: the internet is genuinely reachable.
    case online
    /// Something answered, but not what we asked for — a captive portal.
    case portal
    /// Nothing answered: upstream is down, DNS is dead, or we are being dropped.
    case unreachable
}

enum LinkHealthProbe {
    /// Apple's captive-portal endpoint, which macOS itself polls constantly, so
    /// using it adds no destination the machine was not already contacting.
    ///
    /// It must stay **http**: a portal intercepting an https request produces a
    /// TLS error indistinguishable from a dead link, which is exactly the
    /// distinction this probe exists to make. `Packaging/Info.plist` carries the
    /// matching ATS exception; without it every probe fails and the indicator
    /// sticks on amber.
    static let defaultURL = "http://captive.apple.com/hotspot-detect.html"

    /// Apple serves "Success" in both the title and the body.
    private static let expectedBody = "Success"

    static func run(urlString: String, timeout: TimeInterval = 4) async -> LinkProbeOutcome {
        guard let url = URL(string: urlString), url.host != nil else { return .unreachable }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        // A cached "Success" from before we walked into the hotel would mask the
        // portal that is in front of us now.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("NetFluss/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .portal
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            return body.contains(expectedBody) ? .online : .portal
        } catch {
            return .unreachable
        }
    }
}

/// Derives the menu bar link indicator's state.
///
/// Most of it is free: whether an interface is up, whether it has a real
/// address and a gateway, and which medium carries the default route are all
/// already sampled every second. Only "addressed and routed, but is the
/// internet actually there?" needs a request, and that one is driven by change
/// rather than by a clock — see `shouldProbe`.
@MainActor
final class LinkHealthTracker {
    private enum Constants {
        /// Re-check while everything looks healthy. Cheap insurance, not a
        /// heartbeat — and the free signals below already catch an unplugged
        /// cable or a dropped association within a second, so this interval only
        /// bounds how long a *far-side* failure can hide.
        static let healthyInterval: TimeInterval = 60
        /// Re-check while degraded: this is when someone is watching for recovery.
        static let degradedInterval: TimeInterval = 10
        /// A single dropped request is not an outage. A portal answer is believed
        /// at once, because it is unambiguous.
        static let failuresBeforeLimited = 2
    }

    private(set) var status: LinkStatus = .offline

    /// Last *confirmed* probe verdict. `nil` means never probed, which shows as
    /// online: the indicator only goes amber on evidence, never on ignorance.
    private var verdict: LinkProbeOutcome?
    private var fingerprint: String?
    private var lastProbeAt: Date?
    private var probeInFlight = false
    private var consecutiveFailures = 0

    /// Called whenever the published status changes.
    var onChange: ((LinkStatus) -> Void)?

    func reset() {
        verdict = nil
        fingerprint = nil
        lastProbeAt = nil
        consecutiveFailures = 0
    }

    /// Feed one tick of the state the monitor already has.
    func ingest(
        primaryInterface: String?,
        adapters: [AdapterStatus],
        gatewayIP: String,
        internalIP: String,
        checkInternet: Bool,
        probeURL: String,
        now: Date = Date()
    ) {
        let carrier = Self.physicalCarrier(primaryInterface: primaryInterface, adapters: adapters)
        let medium = Self.medium(for: carrier)

        // 1. States that need no probe at all.
        guard let carrier, carrier.isUp else {
            publish(LinkStatus(health: .offline, medium: medium, interfaceName: carrier?.id ?? "", ssid: nil))
            reset()
            return
        }
        let ssid = carrier.wifiSSID
        if carrier.type == .wifi, (ssid ?? "").isEmpty {
            // The radio is up but not associated with anything.
            publish(LinkStatus(health: .offline, medium: .wifi, interfaceName: carrier.id, ssid: nil))
            reset()
            return
        }
        if Self.isUnusable(internalIP: internalIP, gatewayIP: gatewayIP) {
            // Self-assigned address or no default route: definitively not online,
            // and no request could tell us anything we do not already know.
            publish(LinkStatus(health: .limited, medium: medium, interfaceName: carrier.id, ssid: ssid))
            reset()
            return
        }

        // 2. Addressed and routed. Without the internet check this is as far as
        //    we can honestly go, so green means "the link is up".
        guard checkInternet else {
            publish(LinkStatus(health: .online, medium: medium, interfaceName: carrier.id, ssid: ssid))
            return
        }

        // 3. Probe on change, then on a backoff that depends on the verdict.
        let current = Self.fingerprint(carrier: carrier, gatewayIP: gatewayIP, internalIP: internalIP)
        let linkChanged = fingerprint != current
        if linkChanged {
            fingerprint = current
            // A new network says nothing about the old one's verdict.
            verdict = nil
            consecutiveFailures = 0
        }

        let health: LinkHealth = verdict == .online || verdict == nil ? .online : .limited
        publish(LinkStatus(health: health, medium: medium, interfaceName: carrier.id, ssid: ssid))

        if shouldProbe(linkChanged: linkChanged, now: now) {
            startProbe(urlString: probeURL, now: now)
        }
    }

    // MARK: - Probing

    private func shouldProbe(linkChanged: Bool, now: Date) -> Bool {
        guard !probeInFlight else { return false }
        if linkChanged { return true }
        guard let lastProbeAt else { return true }
        // A failure that has not yet crossed the hysteresis threshold still
        // counts as degraded for scheduling. Otherwise the second failure would
        // be a full healthy interval away and an outage would take twice as
        // long to show as it should.
        let degraded = verdict != .online || consecutiveFailures > 0
        let interval = degraded ? Constants.degradedInterval : Constants.healthyInterval
        return now.timeIntervalSince(lastProbeAt) >= interval
    }

    private func startProbe(urlString: String, now: Date) {
        probeInFlight = true
        lastProbeAt = now
        let url = urlString.isEmpty ? LinkHealthProbe.defaultURL : urlString

        Task { [weak self] in
            let outcome = await LinkHealthProbe.run(urlString: url)
            guard let self else { return }
            self.probeInFlight = false
            self.apply(outcome)
        }
    }

    private func apply(_ outcome: LinkProbeOutcome) {
        switch outcome {
        case .online:
            consecutiveFailures = 0
            verdict = .online
        case .portal:
            // Unambiguous: something answered and it was not the internet.
            consecutiveFailures = 0
            verdict = .portal
        case .unreachable:
            consecutiveFailures += 1
            guard consecutiveFailures >= Constants.failuresBeforeLimited else { return }
            verdict = .unreachable
        }

        guard status.health != .offline else { return }
        let health: LinkHealth = verdict == .online || verdict == nil ? .online : .limited
        publish(
            LinkStatus(
                health: health,
                medium: status.medium,
                interfaceName: status.interfaceName,
                ssid: status.ssid
            )
        )
    }

    private func publish(_ new: LinkStatus) {
        guard new != status else { return }
        status = new
        onChange?(new)
    }

    // MARK: - Interface selection

    /// The physical interface behind the default route.
    ///
    /// With a VPN up, `PrimaryInterface` is the tunnel — but the indicator is
    /// about the connection carrying it, and the VPN already has its own mark,
    /// so tunnels are skipped in favour of the real link underneath.
    static func physicalCarrier(primaryInterface: String?, adapters: [AdapterStatus]) -> AdapterStatus? {
        if let primaryInterface,
           let match = adapters.first(where: { $0.id == primaryInterface }),
           !match.isTunnelInterface {
            return match
        }

        // Fall back to whichever real interface is doing the most work: with a
        // tunnel in front, that is the one actually carrying it.
        return adapters
            .filter { !$0.isTunnelInterface && $0.isUp && ($0.type == .wifi || $0.type == .ethernet) }
            .max { ($0.rxBytes &+ $0.txBytes) < ($1.rxBytes &+ $1.txBytes) }
    }

    static func medium(for adapter: AdapterStatus?) -> LinkMedium {
        switch adapter?.type {
        case .wifi: return .wifi
        case .ethernet: return .ethernet
        default: return .other
        }
    }

    /// An address the system assigned itself, or no way off the subnet.
    static func isUnusable(internalIP: String, gatewayIP: String) -> Bool {
        if internalIP.hasPrefix("169.254.") { return true }
        let gateway = gatewayIP.trimmingCharacters(in: .whitespaces)
        return gateway.isEmpty || gateway == "—"
    }

    private static func fingerprint(carrier: AdapterStatus, gatewayIP: String, internalIP: String) -> String {
        // BSSID included on purpose: roaming to another access point is exactly
        // the moment a working connection can quietly stop working.
        [
            carrier.id,
            carrier.wifiSSID ?? "",
            carrier.wifiDetail?.bssid ?? "",
            gatewayIP,
            internalIP
        ].joined(separator: "|")
    }
}

// MARK: - Glyphs

enum LinkHealthGlyph {
    /// Wi-Fi carries the state in its shape as well as its colour; the cable
    /// symbols have no slash or exclamation variant, so Ethernet is colour-only.
    /// Every lookup falls back, because the newer symbols are not on macOS 13.
    static func symbolName(medium: LinkMedium, health: LinkHealth) -> [String] {
        switch (medium, health) {
        case (.wifi, .online):   return ["wifi"]
        case (.wifi, .limited):  return ["wifi.exclamationmark", "wifi"]
        case (.wifi, .offline):  return ["wifi.slash", "wifi"]
        case (.ethernet, _):     return ["cable.connector", "network"]
        case (.other, .offline): return ["network.slash", "network"]
        case (.other, _):        return ["network"]
        }
    }

    static func image(medium: LinkMedium, health: LinkHealth, pointSize: CGFloat, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        for name in symbolName(medium: medium, health: health) {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Network link")?
                .withSymbolConfiguration(configuration) {
                return image
            }
        }
        return nil
    }
}
