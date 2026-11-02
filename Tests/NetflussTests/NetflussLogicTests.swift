import XCTest
@testable import Netfluss

final class DNSRuleEngineTests: XCTestCase {
    private let servers = ["cloudflare": ["1.1.1.1", "1.0.0.1"], "mine": ["1.1.1.1", "1.0.0.1"],
                           "other": ["9.9.9.9"], "system": []]

    private func input(
        rule target: String,
        health: LinkHealth = .online,
        portal: Bool = false,
        active: String?,
        current: [String]?,
        ssid: String = "Home"
    ) -> DNSRuleEngine.Input {
        DNSRuleEngine.Input(
            enabled: true, helperEnabled: true, ssid: ssid, bssid: nil, linkHealth: health,
            portalSignalAvailable: portal, vpnDNSActive: false, activePresetID: active,
            currentServers: current, presetServers: servers,
            rules: [DNSRule(ssid: "Home", presetID: target), DNSRule(ssid: "Office", presetID: target)],
            fallbackPresetID: nil
        )
    }

    func testAppliesTheRuleOnItsNetwork() {
        XCTAssertEqual(
            DNSRuleEngine.decide(input(rule: "other", active: "system", current: [])),
            .apply(presetID: "other", state: .applied(ssid: "Home", presetID: "other"))
        )
    }

    func testPresetWithTheSameServersCountsAsApplied() {
        let decision = DNSRuleEngine.decide(input(rule: "mine", active: "cloudflare", current: ["1.1.1.1", "1.0.0.1"]))
        XCTAssertEqual(decision, .doNothing(.applied(ssid: "Home", presetID: "mine")))
    }

    func testWaitsForACaptivePortal() {
        let decision = DNSRuleEngine.decide(input(rule: "other", health: .limited, portal: true, active: "system", current: []))
        XCTAssertEqual(decision, .doNothing(.waitingForPortal(ssid: "Home")))
    }

    func testDoesNothingOffline() {
        let decision = DNSRuleEngine.decide(input(rule: "other", health: .offline, active: "system", current: []))
        XCTAssertEqual(decision, .doNothing(.noRule))
    }

    @MainActor
    private func writes(seconds: Int, input: (Int) -> DNSRuleEngine.Input) -> [Int] {
        let engine = DNSRuleEngine()
        let start = Date(timeIntervalSince1970: 0)
        return (0...seconds).filter { engine.evaluate(input($0), now: start.addingTimeInterval(Double($0))) != nil }
    }

    @MainActor
    func testAWriteThatNeverTakesBacksOff() {
        let times = writes(seconds: 640) { _ in self.input(rule: "other", active: "system", current: []) }
        XCTAssertEqual(times, [2, 7, 17, 37, 77, 157, 317, 617])
    }

    @MainActor
    func testAWriteThatTakesHappensOnce() {
        var written = false
        let engine = DNSRuleEngine()
        let start = Date(timeIntervalSince1970: 0)
        var times: [Int] = []
        for second in 0...60 {
            let current = written ? "other" : "system"
            let decision = engine.evaluate(
                input(rule: "other", active: current, current: written ? ["9.9.9.9"] : []),
                now: start.addingTimeInterval(Double(second))
            )
            if decision != nil { times.append(second); written = true }
        }
        XCTAssertEqual(times, [2])
    }

    @MainActor
    func testANewNetworkStartsTheBackoffAgain() {
        let times = writes(seconds: 30) { second in
            self.input(rule: "other", active: "system", current: [], ssid: second < 15 ? "Home" : "Office")
        }
        XCTAssertEqual(times, [2, 7, 17, 22])
    }
}

final class StatisticsRecoveryTests: XCTestCase {
    private var directory: URL!
    private var archive: URL { directory.appendingPathComponent("statistics.json") }
    private var backup: URL { directory.appendingPathComponent("statistics.backup.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func record(_ megabytes: UInt64, in store: StatisticsStore) async {
        let delta = StatisticsAdapterDelta(id: "en0", displayName: "Wi-Fi", downloadBytes: megabytes * 1_000_000, uploadBytes: 0)
        await store.recordAdapterDeltas([delta], at: Date())
        await store.flush(force: true)
    }

    private func total(_ store: StatisticsStore) async -> UInt64 {
        await store.usageSummary(now: Date(), excludeTunnels: false).month.downloadBytes / 1_000_000
    }

    private var unreadableCopies: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.contains("unreadable") }
    }

    func testHistorySurvivesAReload() async {
        await record(5, in: StatisticsStore(url: archive))
        let reloaded = StatisticsStore(url: archive)
        await record(7, in: reloaded)
        let megabytes = await total(reloaded)
        XCTAssertEqual(megabytes, 12)
    }

    func testDamagedArchiveIsKeptAndRestoredFromBackup() async throws {
        await record(5, in: StatisticsStore(url: archive))
        await record(7, in: StatisticsStore(url: archive))   // takes the backup: 5 MB
        try Data("{ not json".utf8).write(to: archive)

        let store = StatisticsStore(url: archive)
        await record(1, in: store)
        let megabytes = await total(store)

        XCTAssertEqual(megabytes, 6)
        let copy = try XCTUnwrap(unreadableCopies.first)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(copy)), Data("{ not json".utf8))
    }

    func testDamagedArchiveWithoutBackupIsStillKept() async throws {
        try Data("garbage".utf8).write(to: archive)
        await record(2, in: StatisticsStore(url: archive))
        let copy = try XCTUnwrap(unreadableCopies.first)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(copy)), Data("garbage".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    func testArchiveThatCannotBeMovedIsNeverOverwritten() async throws {
        try Data("precious".utf8).write(to: archive)
        // Occupy the name it would move to, so the move fails while the folder
        // stays writable and a save would still succeed if it were attempted.
        let now = Int(Date().timeIntervalSince1970)
        for second in now...(now + 10) {
            try Data().write(to: directory.appendingPathComponent("statistics.unreadable-\(second).json"))
        }
        await record(3, in: StatisticsStore(url: archive))
        XCTAssertEqual(try Data(contentsOf: archive), Data("precious".utf8))
    }

    func testBackupIsRefreshedOnlyOnceADay() async throws {
        let store = StatisticsStore(url: archive)
        await record(1, in: store)
        await record(1, in: store)
        let first = try Data(contentsOf: backup)
        await record(1, in: store)
        XCTAssertEqual(try Data(contentsOf: backup), first)

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: backup.path)
        await record(40, in: store)
        XCTAssertNotEqual(try Data(contentsOf: backup), first)
    }
}

final class CounterTests: XCTestCase {
    func testRateIgnoresResetsAndGlitches() {
        XCTAssertEqual(InterfaceSampler.rate(current: 2_000, previous: 1_000, deltaTime: 1), 1_000)
        XCTAssertEqual(InterfaceSampler.rate(current: 5, previous: 1_000, deltaTime: 1), 0)
        XCTAssertEqual(InterfaceSampler.rate(current: 1 << 40, previous: 0, deltaTime: 1), 0)
        XCTAssertEqual(InterfaceSampler.rate(current: 10, previous: nil, deltaTime: 1), 0)
    }

    func testRetryDelaysGrowToALimit() {
        XCTAssertEqual(DNSRuleEngine.retryDelay(afterAttempts: 1), 5)
        XCTAssertEqual(DNSRuleEngine.retryDelay(afterAttempts: 4), 40)
        XCTAssertEqual(DNSRuleEngine.retryDelay(afterAttempts: 12), 300)
    }
}

final class ProcessRunnerTests: XCTestCase {
    func testCollectsOutputAndStatus() {
        let result = ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        XCTAssertEqual(result.stdoutText, "out\n")
        XCTAssertEqual(result.stderrText, "err\n")
        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(result.timedOut)
    }

    func testAToolThatHangsIsStopped() {
        let started = Date()
        let result = ProcessRunner.run("/bin/sleep", ["30"], timeout: 0.3)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testFillingBothPipesDoesNotDeadlock() {
        let script = "i=0; while [ $i -lt 40000 ]; do echo xxxxxxxx; echo yyyyyyyy >&2; i=$((i+1)); done"
        let result = ProcessRunner.run("/bin/sh", ["-c", script], timeout: 20)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.count, 360_000)
        XCTAssertEqual(result.stderr.count, 360_000)
    }

    func testAMissingToolIsReported() {
        XCTAssertFalse(ProcessRunner.run("/nonexistent/tool", []).launched)
    }
}

final class LinkGlyphTests: XCTestCase {
    func testEveryStateThatColourAloneWouldCarryGetsABadge() {
        XCTAssertNotNil(LinkHealthGlyph.badgeName(medium: .ethernet, health: .limited))
        XCTAssertNotNil(LinkHealthGlyph.badgeName(medium: .ethernet, health: .offline))
        XCTAssertNotNil(LinkHealthGlyph.badgeName(medium: .other, health: .limited))
        XCTAssertNil(LinkHealthGlyph.badgeName(medium: .ethernet, health: .online))
        XCTAssertNil(LinkHealthGlyph.badgeName(medium: .wifi, health: .limited))
    }
}

final class AdapterTests: XCTestCase {
    func testPhysicalCarrierSkipsTunnels() {
        func adapter(_ id: String, tunnel: Bool, bytes: UInt64) -> AdapterStatus {
            AdapterStatus(id: id, displayName: id, type: tunnel ? .other : .ethernet, isTunnelInterface: tunnel,
                          isUp: true, linkSpeedBps: nil, wifiMode: nil, wifiTxRateMbps: nil, wifiSSID: nil,
                          wifiDetail: nil, rxBytes: bytes, txBytes: 0, rxRateBps: 0, txRateBps: 0)
        }
        let adapters = [adapter("en0", tunnel: false, bytes: 1), adapter("en7", tunnel: false, bytes: 9), adapter("utun3", tunnel: true, bytes: 99)]
        XCTAssertEqual(LinkHealthTracker.physicalCarrier(primaryInterface: "en0", adapters: adapters)?.id, "en0")
        XCTAssertEqual(LinkHealthTracker.physicalCarrier(primaryInterface: "utun3", adapters: adapters)?.id, "en7")
    }

    func testWithoutTrafficIgnoresLiveCounters() {
        let busy = AdapterStatus(id: "en0", displayName: "Wi-Fi", type: .wifi, isTunnelInterface: false, isUp: true,
                                 linkSpeedBps: nil, wifiMode: nil, wifiTxRateMbps: 866, wifiSSID: "Home", wifiDetail: nil,
                                 rxBytes: 5, txBytes: 6, rxRateBps: 7, txRateBps: 8)
        let idle = AdapterStatus(id: "en0", displayName: "Wi-Fi", type: .wifi, isTunnelInterface: false, isUp: true,
                                 linkSpeedBps: nil, wifiMode: nil, wifiTxRateMbps: 144, wifiSSID: "Home", wifiDetail: nil,
                                 rxBytes: 0, txBytes: 0, rxRateBps: 0, txRateBps: 0)
        XCTAssertEqual(busy.withoutTraffic, idle.withoutTraffic)
    }
}

final class PreferenceSearchTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func labels(in source: String) -> [String] {
        let pattern = #/(?:LText|PreferenceNote)\(\s*"((?:[^"\\]|\\.)*)"/#
        return source.matches(of: pattern).map { String($0.1).replacingOccurrences(of: "\\\"", with: "\"") }
    }

    func testEveryEntryIsATranslatedString() throws {
        let catalogue = try String(contentsOf: repository.appendingPathComponent("Packaging/Resources/en.lproj/Localizable.strings"), encoding: .utf8)
        for entry in PreferenceSearch.entries {
            let key = entry.key.replacingOccurrences(of: "\"", with: "\\\"")
            XCTAssertTrue(catalogue.contains("\"\(key)\" ="), entry.key)
        }
    }

    /// Fails when a setting is added to Preferences without being made findable.
    func testEverySettingOnThePanesCanBeFound() throws {
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/Netfluss/PreferencesView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "if selectedPane == .general"))
        let end = try XCTUnwrap(source.range(of: "private var launchAtLoginControls"))
        let indexed = Set(PreferenceSearch.entries.map(\.key))
        for label in labels(in: String(source[start.lowerBound..<end.lowerBound])) where label.count > 2 {
            XCTAssertTrue(indexed.contains(label), label)
        }
    }

    func testMatchesEveryWordInEitherLanguage() {
        let entries = [PreferenceSearch.Entry("Launch at login", .general),
                       PreferenceSearch.Entry("Rate alignment", .appearance)]
        let german: (String) -> String = { $0 == "Launch at login" ? "Beim Anmelden starten" : $0 }

        XCTAssertEqual(PreferenceSearch.matches(for: "login", in: entries, localized: german).map(\.pane), [.general])
        XCTAssertEqual(PreferenceSearch.matches(for: "ANMELDEN starten", in: entries, localized: german).map(\.pane), [.general])
        XCTAssertEqual(PreferenceSearch.matches(for: "login align", in: entries, localized: german), [])
        XCTAssertEqual(PreferenceSearch.matches(for: "   ", in: entries, localized: german), [])
    }

    func testShorterLabelsComeBeforeExplanations() {
        let entries = [PreferenceSearch.Entry("Shows the resolver in use on this network", .dns),
                       PreferenceSearch.Entry("Resolver", .appearance)]
        XCTAssertEqual(PreferenceSearch.matches(for: "resolver", in: entries, localized: { $0 }).first?.pane, .appearance)
    }
}

final class VPNSupportTests: XCTestCase {
    func testBundledToolsNeedMacOS14() {
        XCTAssertFalse(VPNManager.supportsBundledTools(on: OperatingSystemVersion(majorVersion: 13, minorVersion: 7, patchVersion: 8)))
        XCTAssertTrue(VPNManager.supportsBundledTools(on: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)))
        XCTAssertTrue(VPNManager.supportsBundledTools(on: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)))
    }
}
