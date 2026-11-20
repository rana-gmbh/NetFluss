import XCTest
@testable import Netfluss

final class DNSPresetModelTests: XCTestCase {
    func testPresetsSavedByOlderVersionsDecodeAsPlain() throws {
        let json = #"[{"id":"x","name":"Mine","servers":["9.9.9.9"],"isBuiltIn":false}]"#
        let presets = try JSONDecoder().decode([DNSPreset].self, from: Data(json.utf8))
        XCTAssertEqual(presets.first?.transport, nil)
        XCTAssertEqual(presets.first?.target, .plain(["9.9.9.9"]))
    }

    func testEncryptedPresetsRoundTrip() throws {
        let presets = [
            DNSPreset(id: "a", name: "A", servers: ["1.1.1.1"], isBuiltIn: false, transport: .https(url: "https://a.example/dns-query")),
            DNSPreset(id: "b", name: "B", servers: ["1.1.1.1"], isBuiltIn: false, transport: .tls(serverName: "b.example")),
        ]
        let decoded = try JSONDecoder().decode([DNSPreset].self, from: JSONEncoder().encode(presets))
        XCTAssertEqual(decoded, presets)
    }

    func testBuiltInsAreValidAndUnique() {
        let ids = DNSPreset.builtIn.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for preset in DNSPreset.builtIn {
            XCTAssertTrue(DNSEntryValidator.isValid(preset), preset.id)
        }
        for preset in DNSPreset.encryptedBuiltIn {
            XCTAssertFalse(preset.servers.isEmpty, preset.id)
            if case .https(let url) = preset.transport { XCTAssertTrue(url.hasSuffix("/dns-query"), preset.id) }
        }
        // OpenDNS offers no DNS-over-TLS.
        XCTAssertFalse(ids.contains("opendns-dot"))
        XCTAssertTrue(ids.contains("opendns-doh"))
    }

    func testNewEncryptedBuiltInsAreHiddenOnce() throws {
        let suite = "NetflussTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["google"], forKey: "hiddenDNSPresets")

        DNSPreset.hideNewEncryptedBuiltIns(defaults: defaults)
        let hidden = defaults.stringArray(forKey: "hiddenDNSPresets") ?? []
        XCTAssertTrue(hidden.contains("google"))
        XCTAssertTrue(DNSPreset.encryptedBuiltIn.allSatisfy { hidden.contains($0.id) })
        XCTAssertFalse(hidden.contains("cloudflare"))

        // The user shows one; a later launch must not hide it again.
        defaults.set(hidden.filter { $0 != "quad9-doh" }, forKey: "hiddenDNSPresets")
        DNSPreset.hideNewEncryptedBuiltIns(defaults: defaults)
        XCTAssertFalse((defaults.stringArray(forKey: "hiddenDNSPresets") ?? []).contains("quad9-doh"))
    }
}

final class DNSEntryValidatorTests: XCTestCase {
    func testIPAddresses() {
        XCTAssertTrue(DNSEntryValidator.isIPAddress("1.1.1.1"))
        XCTAssertTrue(DNSEntryValidator.isIPAddress("2606:4700:4700::1111"))
        XCTAssertFalse(DNSEntryValidator.isIPAddress("1.1.1"))
        XCTAssertFalse(DNSEntryValidator.isIPAddress("dns.google"))
        XCTAssertFalse(DNSEntryValidator.isIPAddress("1.1.1.1; rm -rf /"))
        XCTAssertFalse(DNSEntryValidator.isIPAddress(""))
    }

    func testDoHURLs() {
        XCTAssertNotNil(DNSEntryValidator.normalizedDoHURL("https://dns.example.com/dns-query"))
        XCTAssertNotNil(DNSEntryValidator.normalizedDoHURL("  https://dns.example.com:8443/dns-query "))
        XCTAssertNil(DNSEntryValidator.normalizedDoHURL("http://dns.example.com/dns-query"))
        XCTAssertNil(DNSEntryValidator.normalizedDoHURL("dns.example.com/dns-query"))
        XCTAssertNil(DNSEntryValidator.normalizedDoHURL("https://user:pw@dns.example.com/dns-query"))
        XCTAssertNil(DNSEntryValidator.normalizedDoHURL("https://dns.example.com/dns-query?x=1"))
        XCTAssertNil(DNSEntryValidator.normalizedDoHURL("https://dns example.com/"))
        XCTAssertNil(DNSEntryValidator.normalizedDoHURL("https:///dns-query"))
    }

    func testServerNames() {
        XCTAssertTrue(DNSEntryValidator.isValidServerName("dns.google"))
        XCTAssertTrue(DNSEntryValidator.isValidServerName("one.one.one.one."))
        XCTAssertFalse(DNSEntryValidator.isValidServerName("router"))
        XCTAssertFalse(DNSEntryValidator.isValidServerName("1.1.1.1"))
        XCTAssertFalse(DNSEntryValidator.isValidServerName("-bad.example"))
        XCTAssertFalse(DNSEntryValidator.isValidServerName("bad..example"))
        XCTAssertFalse(DNSEntryValidator.isValidServerName("dns.example.com/path"))
    }

    func testDoTNeedsAnAddressToDial() {
        let noIP = DNSPreset(id: "x", name: "X", servers: [], isBuiltIn: false, transport: .tls(serverName: "dns.example.com"))
        XCTAssertFalse(DNSEntryValidator.isValid(noIP))
        let doh = DNSPreset(id: "y", name: "Y", servers: [], isBuiltIn: false, transport: .https(url: "https://dns.example.com/dns-query"))
        XCTAssertTrue(DNSEntryValidator.isValid(doh))
    }
}

final class DNSPresetMatcherTests: XCTestCase {
    private let cloudflare = DNSPreset.builtIn.first { $0.id == "cloudflare" }!
    private let cloudflareDoH = DNSPreset.builtIn.first { $0.id == "cloudflare-doh" }!
    private var presets: [DNSPreset] { DNSPreset.builtIn }

    private func installed(_ preset: DNSPreset, enabled: Bool = true, paused: Bool = false) -> EncryptedDNSStatus {
        .installed(EncryptedDNSConfig(transport: preset.transport!, servers: preset.servers, paused: paused), enabled: enabled)
    }

    func testActiveEncryptedConfigurationWinsOverServers() {
        let id = DNSPresetMatcher.activePresetID(servers: ["8.8.8.8", "8.8.4.4"], encrypted: installed(cloudflareDoH), presets: presets)
        XCTAssertEqual(id, "cloudflare-doh")
    }

    func testPausedOrNotSwitchedOnFallsBackToServers() {
        XCTAssertEqual(DNSPresetMatcher.activePresetID(
            servers: cloudflare.servers, encrypted: installed(cloudflareDoH, paused: true), presets: presets), "cloudflare")
        XCTAssertEqual(DNSPresetMatcher.activePresetID(
            servers: [], encrypted: installed(cloudflareDoH, enabled: false), presets: presets), "system")
    }

    /// Bootstrap IPs say nothing about encryption, so plain servers that happen
    /// to equal them must not light up the encrypted preset.
    func testPlainServersNeverMatchAnEncryptedPreset() {
        let doh = DNSPreset(id: "doh", name: "D", servers: ["9.9.9.9"], isBuiltIn: false, transport: .https(url: "https://x.example/dns-query"))
        XCTAssertNil(DNSPresetMatcher.activePresetID(servers: ["9.9.9.9"], encrypted: .notInstalled, presets: [doh]))
    }

    func testUnknownServersMatchNothing() {
        XCTAssertNil(DNSPresetMatcher.activePresetID(servers: nil, encrypted: .notInstalled, presets: presets))
        XCTAssertNil(DNSPresetMatcher.activePresetID(servers: ["10.0.0.1"], encrypted: .unavailable, presets: presets))
    }
}

final class EncryptedDNSRuleTests: XCTestCase {
    private let doh = DNSResolverTarget.encrypted(.https(url: "https://cloudflare-dns.com/dns-query"), servers: ["1.1.1.1"])
    private var config: EncryptedDNSConfig {
        EncryptedDNSConfig(transport: .https(url: "https://cloudflare-dns.com/dns-query"), servers: ["1.1.1.1"], paused: false)
    }

    private func input(
        rule target: String,
        helper: Bool = true,
        encrypted: EncryptedDNSStatus = .notInstalled,
        refused: Bool = false,
        health: LinkHealth = .online,
        active: String? = nil,
        current: [String]? = []
    ) -> DNSRuleEngine.Input {
        DNSRuleEngine.Input(
            enabled: true, helperEnabled: helper, ssid: "Home", bssid: nil, linkHealth: health,
            portalSignalAvailable: true, vpnDNSActive: false, activePresetID: active,
            currentServers: current,
            presetTargets: ["doh": doh, "plain": .plain(["1.1.1.1"]), "system": .plain([])],
            encrypted: encrypted, encryptedRefused: refused,
            rules: [DNSRule(ssid: "Home", presetID: target)],
            fallbackPresetID: nil
        )
    }

    func testEncryptedTargetNeedsNoHelper() {
        XCTAssertEqual(DNSRuleEngine.decide(input(rule: "doh", helper: false)),
                       .apply(presetID: "doh", state: .applied(ssid: "Home", presetID: "doh")))
    }

    func testPlainTargetStillNeedsTheHelper() {
        XCTAssertEqual(DNSRuleEngine.decide(input(rule: "plain", helper: false)), .doNothing(.needsHelper))
    }

    func testLeavingEncryptedDNSForServersAlreadySetNeedsNoHelper() {
        let decision = DNSRuleEngine.decide(input(
            rule: "plain", helper: false, encrypted: .installed(config, enabled: true), current: ["1.1.1.1"]))
        XCTAssertEqual(decision, .apply(presetID: "plain", state: .applied(ssid: "Home", presetID: "plain")))
    }

    /// Same IPs, different resolver: encrypted DNS on means the plain preset
    /// is not in effect, whatever the per-service servers say.
    func testPlainIsNotAppliedWhileEncryptedIsOn() {
        let decision = DNSRuleEngine.decide(input(rule: "plain", encrypted: .installed(config, enabled: true), current: ["1.1.1.1"]))
        XCTAssertEqual(decision, .apply(presetID: "plain", state: .applied(ssid: "Home", presetID: "plain")))
    }

    func testActiveEncryptedTargetCountsAsApplied() {
        XCTAssertEqual(DNSRuleEngine.decide(input(rule: "doh", encrypted: .installed(config, enabled: true))),
                       .doNothing(.applied(ssid: "Home", presetID: "doh")))
    }

    func testWaitsForTheUserInsteadOfSavingAgain() {
        XCTAssertEqual(DNSRuleEngine.decide(input(rule: "doh", encrypted: .installed(config, enabled: false))),
                       .doNothing(.waitingForEncryptedDNS(presetID: "doh")))
    }

    func testARefusedPromptIsNotRepeated() {
        XCTAssertEqual(DNSRuleEngine.decide(input(rule: "doh", refused: true)),
                       .doNothing(.encryptedDNSUnavailable(presetID: "doh")))
    }

    func testUnavailableInThisBuild() {
        XCTAssertEqual(DNSRuleEngine.decide(input(rule: "doh", encrypted: .unavailable)),
                       .doNothing(.encryptedDNSUnavailable(presetID: "doh")))
    }

    func testAHandPickHoldsOnItsNetworkOnly() {
        var here = input(rule: "doh")
        here.manualOverrideNetwork = "Home"
        XCTAssertEqual(DNSRuleEngine.decide(here), .doNothing(.manualOverride(ssid: "Home")))

        var elsewhere = input(rule: "doh")
        elsewhere.manualOverrideNetwork = "Cafe"
        XCTAssertEqual(DNSRuleEngine.decide(elsewhere),
                       .apply(presetID: "doh", state: .applied(ssid: "Home", presetID: "doh")))
    }

    func testCaptivePortalPausesEncryptedDNS() {
        XCTAssertEqual(DNSRuleEngine.decide(input(rule: "plain", encrypted: .installed(config, enabled: true), health: .limited)),
                       .pauseEncrypted(state: .waitingForPortal(ssid: "Home")))
        XCTAssertEqual(DNSRuleEngine.decide(input(rule: "doh", health: .limited)),
                       .doNothing(.waitingForPortal(ssid: "Home")))
    }
}

@MainActor
final class EncryptedDNSControllerTests: XCTestCase {
    private final class FakeStore: EncryptedDNSStore {
        var config: EncryptedDNSConfig?
        var enabled = false
        var failLoad = false
        var failSave = false
        var saves: [EncryptedDNSConfig] = []

        func load() async throws -> (config: EncryptedDNSConfig?, enabled: Bool) {
            if failLoad { throw NSError(domain: "test", code: 1) }
            return (config, enabled)
        }

        func save(_ config: EncryptedDNSConfig, description: String) async throws {
            if failSave { throw NSError(domain: "test", code: 2) }
            saves.append(config)
            self.config = config
        }

        func remove() async throws { config = nil }
    }

    private let preset = DNSPreset.builtIn.first { $0.id == "quad9-dot" }!

    func testActivatePauseResume() async {
        let store = FakeStore()
        let controller = EncryptedDNSController(store: store)
        await controller.refresh()
        XCTAssertEqual(controller.status, .notInstalled)

        let error = await controller.activate(preset, userInitiated: true)
        XCTAssertNil(error)
        XCTAssertEqual(controller.status.awaitingUser?.transport, preset.transport)

        store.enabled = true
        await controller.refresh()
        XCTAssertEqual(controller.status.activeTarget, preset.target)

        _ = await controller.pause()
        XCTAssertEqual(store.config?.paused, true)
        XCTAssertNil(controller.status.activeTarget)

        _ = await controller.resume()
        XCTAssertEqual(store.config?.paused, false)
        XCTAssertEqual(controller.status.activeTarget, preset.target)
    }

    func testPauseWithoutAConfigurationDoesNothing() async {
        let store = FakeStore()
        let controller = EncryptedDNSController(store: store)
        await controller.refresh()
        _ = await controller.pause()
        XCTAssertTrue(store.saves.isEmpty)
    }

    func testARefusedSaveIsOnlyRetriedByTheUser() async {
        let store = FakeStore()
        store.failSave = true
        let controller = EncryptedDNSController(store: store)
        await controller.refresh()
        let error = await controller.activate(preset, userInitiated: true)
        XCTAssertNotNil(error)
        XCTAssertTrue(controller.saveRefused)

        store.failSave = false
        _ = await controller.activate(preset, userInitiated: false)
        XCTAssertTrue(store.saves.isEmpty, "an automatic switch must not bring the prompt back")

        _ = await controller.activate(preset, userInitiated: true)
        XCTAssertEqual(store.saves.count, 1)
        XCTAssertFalse(controller.saveRefused)
    }

    func testABuildWithoutTheEntitlementIsUnavailable() async {
        let controller = EncryptedDNSController(store: FakeStore(), hasEntitlement: false)
        await controller.refresh()
        XCTAssertEqual(controller.status, .unavailable)
        // The test runner itself is an unsigned raw build.
        XCTAssertFalse(EncryptedDNSController.processHasDNSSettingsEntitlement())
    }

    func testALoadFailureMeansUnavailable() async {
        let store = FakeStore()
        store.failLoad = true
        let controller = EncryptedDNSController(store: store)
        await controller.refresh()
        XCTAssertEqual(controller.status, .unavailable)
    }
}
