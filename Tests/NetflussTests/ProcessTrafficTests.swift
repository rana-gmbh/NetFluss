import Foundation
import Testing
@testable import Netfluss

/// netstat parsing and Top Apps rates. Lines are verbatim `netstat -n -b -v`
/// output from macOS 27.2 unless marked as macOS 15.
@Suite
struct NetstatParserTests {
    private func parse(_ lines: String...) -> [String: ProcessConnectionSnapshot] {
        ProcessNetworkSampler.parseNetstat(lines.joined(separator: "\n")) { "pid\($0)" }
    }

    @Test func truncatedNameWithSpacesStillYieldsThePID() throws {
        let result = parse(
            "tcp4       0      0  192.168.1.94.57829     104.18.15.251.443      ESTABLISHED         5998         4439  131072  131860 Browser Helper (:82406  00102 00000008 0000000000522792 00000080 04000900      2      0 000000"
        )
        let connection = try #require(result.values.first)
        #expect(result.count == 1)
        #expect(connection.name == "pid82406")
        #expect(connection.downloadBytes == 5998)
        #expect(connection.uploadBytes == 4439)
        #expect(connection.source == .internetSocket)
        #expect(!connection.isLoopback)
    }

    @Test func udpLineHasNoStateColumn() throws {
        let result = parse(
            "udp4       0      0  192.168.1.94.49153     172.64.41.3.443                           15638         5637 1048576   29040 Browser Helper (:82406  00102 00000000 000000000052278d 00000000 04200900      1      0 000002"
        )
        let connection = try #require(result.values.first)
        #expect(connection.downloadBytes == 15638)
        #expect(connection.uploadBytes == 5637)
        #expect(connection.name == "pid82406")
    }

    @Test func networkSourceControlSocketIsParsed() throws {
        let result = parse(
            "kctl       0      0          160          180  131072    2048          launchd:1      00182 00000000 0000000000000d11 00008001 00000000      1      0 000000      1     10 com.apple.netsrc",
            // Other control sockets are not traffic.
            "kctl       0      0            0          577 2097152 1048576   UserEventAgent:976    00182 00000000 0000000000001885 00008000 00000000      1      0 000000      1      2 com.apple.flow-divert"
        )
        let connection = try #require(result.values.first)
        #expect(result.count == 1)
        #expect(connection.source == .networkSource)
        #expect(connection.downloadBytes == 160)
        #expect(connection.uploadBytes == 180)
        #expect(connection.name == "pid1")
        #expect(!connection.isLoopback)
    }

    @Test func ipv6AddressIsNotMistakenForThePIDToken() throws {
        let result = parse(
            "tcp6       0      0  fe80::ca1:8e82:4.62385 fe80::caa:781:b2.49154 ESTABLISHED     13177052       495745  650864  131376         rapportd:1008   00102 00000008 0000000000497948 00080083 04000900      2      0 000000"
        )
        let connection = try #require(result.values.first)
        #expect(connection.name == "pid1008")
        #expect(connection.downloadBytes == 13177052)
    }

    @Test func macOS15NumericPIDColumn() throws {
        // macOS 15 prints the PID as its own column, four after rxbytes.
        let result = parse(
            "tcp4       0      0  192.168.1.5.50000      17.253.1.1.443         ESTABLISHED      1000      200  131072  131072   4321      0 00102 00000008",
            "udp4       0      0  192.168.1.5.50001      17.253.1.2.443                          3000      400  131072  131072   4322      0 00102 00000008"
        )
        #expect(Set(result.values.map(\.name)) == ["pid4321", "pid4322"])
    }

    @Test func loopbackSocketsAreFlagged() {
        let result = parse(
            "tcp4       0      0  127.0.0.1.57343        127.0.0.1.57342        ESTABLISHED    291314864     95227000  464814  146988        steam_osx:17493  00002 00000004 00000000004e2291 00000081 01000800      2      0 000000",
            "tcp6       0      0  ::1.631                ::1.50123              ESTABLISHED          100          200  131072  131072            cupsd:300    00002 00000004 00000000004e2291 00000081 01000800      2      0 000000",
            "tcp4       0      0  192.168.1.94.57801     185.125.25.105.443     ESTABLISHED        15720         1558  262144  131400           kDrive:1410   00002 00000000 0000000000522668 00000081 04002900      3      0 000000"
        )
        let loopbackNames = Set(result.values.filter(\.isLoopback).map(\.name))
        #expect(loopbackNames == ["pid17493", "pid300"])
        #expect(result.values.filter { !$0.isLoopback }.map(\.name) == ["pid1410"])
    }

    @Test func headerAndIdleSocketsAreSkipped() {
        let result = parse(
            "Active Internet connections",
            "Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs",
            "tcp4       0      0  192.168.1.94.57000     1.2.3.4.443            ESTABLISHED            0            0  131072  131072           idle:77      00102 00000008 0000000000522792 00000080 04000900      2      0 000000"
        )
        #expect(result.isEmpty)
    }
}

@Suite
struct TopAppsRateTests {
    private func socket(_ id: String, _ name: String, rx: UInt64, tx: UInt64) -> ProcessConnectionSnapshot {
        ProcessConnectionSnapshot(id: id, name: name, source: .internetSocket, downloadBytes: rx, uploadBytes: tx)
    }

    @Test func ratesComeFromTheDiffOfTwoSnapshots() throws {
        let previous = ["a": socket("a", "Safari", rx: 1_000, tx: 100)]
        let current = [
            "a": socket("a", "Safari", rx: 5_000, tx: 300),
            // Opened since the last snapshot: all of its bytes are new.
            "b": socket("b", "Mail", rx: 600, tx: 0),
        ]
        let apps = ProcessNetworkSampler.rates(
            from: ProcessNetworkSampler.appDeltas(current: current, previous: previous),
            elapsed: 2,
            limit: .max
        )
        #expect(apps.map(\.name) == ["Safari", "Mail"])
        let safari = try #require(apps.first)
        #expect(safari.rxRateBps == 2_000)
        #expect(safari.txRateBps == 100)
        #expect(apps.last?.rxRateBps == 300)
    }

    @Test func closedSocketsAndUnchangedOnesDropOut() {
        let previous = [
            "a": socket("a", "Safari", rx: 1_000, tx: 100),
            "gone": socket("gone", "Mail", rx: 9_000, tx: 9_000),
        ]
        let current = ["a": socket("a", "Safari", rx: 1_000, tx: 100)]
        let deltas = ProcessNetworkSampler.appDeltas(current: current, previous: previous)
        #expect(ProcessNetworkSampler.rates(from: deltas, elapsed: 2, limit: .max).isEmpty)
    }

    @Test func networkSourceAndSocketsOfOneAppAreNotAddedUp() {
        // WebKit traffic can appear both as sockets and as a netsrc control
        // socket; the larger of the two is taken, never the sum.
        let current = [
            "s": socket("s", "Safari", rx: 1_000, tx: 0),
            "n": ProcessConnectionSnapshot(id: "n", name: "Safari", source: .networkSource, downloadBytes: 4_000, uploadBytes: 0),
        ]
        let deltas = ProcessNetworkSampler.appDeltas(current: current, previous: [:])
        #expect(deltas["Safari"]?.rx == 4_000)
    }
}

@Suite
struct RxFallbackDetectorTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private let tick: UInt64 = 64 * 1024

    /// Feeds `seconds` one-second ticks with a frozen rx counter and `txPerTick`
    /// of upload; returns the events.
    private func frozen(
        _ detector: inout RxFallbackDetector,
        seconds: Int,
        txPerTick: UInt64,
        from offset: Int = 0
    ) -> [RxFallbackDetector.Event] {
        (0...seconds).compactMap { second in
            detector.observe(
                id: "en0",
                rxBytes: 1_119_232,
                txBytes: UInt64(offset + second) * txPerTick,
                at: start.addingTimeInterval(Double(offset + second))
            )
        }
    }

    @Test func frozenCounterWithUploadLatches() {
        var detector = RxFallbackDetector()
        let events = frozen(&detector, seconds: 20, txPerTick: tick)
        #expect(events == [.latched("en0")])
        #expect(detector.broken == ["en0"])
    }

    @Test func idleAdapterIsNotFlagged() {
        // ARP/mDNS chatter only: rx standing still is normal here.
        var detector = RxFallbackDetector()
        #expect(frozen(&detector, seconds: 120, txPerTick: 200).isEmpty)
    }

    @Test func notFlaggedBeforeTheThreshold() {
        var detector = RxFallbackDetector()
        #expect(frozen(&detector, seconds: 19, txPerTick: tick).isEmpty)
    }

    @Test func movingCounterRecoversAfterThreeTicks() {
        var detector = RxFallbackDetector()
        _ = frozen(&detector, seconds: 20, txPerTick: tick)
        var events: [RxFallbackDetector.Event] = []
        for step in 1...3 {
            let at = start.addingTimeInterval(Double(20 + step))
            if let event = detector.observe(id: "en0", rxBytes: 1_119_232 + UInt64(step) * 50_000, txBytes: 0, at: at) {
                events.append(event)
            }
        }
        #expect(events == [.recovered("en0")])
        #expect(detector.broken.isEmpty)
    }

    @Test func aSingleBlipDoesNotRecover() {
        var detector = RxFallbackDetector()
        _ = frozen(&detector, seconds: 20, txPerTick: tick)
        let values: [UInt64] = [2_000_000, 2_000_000, 3_000_000, 4_000_000, 4_000_000]
        let events = values.enumerated().compactMap { index, rx in
            detector.observe(id: "en0", rxBytes: rx, txBytes: 0, at: start.addingTimeInterval(Double(21 + index)))
        }
        // Moves on ticks 1, 3 and 4: never three in a row.
        #expect(events.isEmpty)
        #expect(detector.broken == ["en0"])
    }

    @Test func forcedFallbackLatchesAtOnceAndStays() {
        var detector = RxFallbackDetector()
        #expect(detector.observe(id: "en0", rxBytes: 1, txBytes: 1, at: start, force: true) == .latched("en0"))
        for step in 1...10 {
            let event = detector.observe(
                id: "en0", rxBytes: UInt64(step) * 1_000, txBytes: 1, at: start.addingTimeInterval(Double(step)), force: true
            )
            #expect(event == nil)
        }
        #expect(detector.broken == ["en0"])
    }

    @Test func wakeResetKeepsTheFlagAndRestartsTheClocks() {
        var detector = RxFallbackDetector()
        _ = frozen(&detector, seconds: 20, txPerTick: tick)
        detector.resetClocks()
        // A counter that jumped across sleep must not count as movement.
        #expect(detector.observe(id: "en0", rxBytes: 99_000_000, txBytes: 0, at: start.addingTimeInterval(100)) == nil)
        #expect(detector.broken == ["en0"])
    }

    @Test func relatchesAfterRecoveringWhenItFreezesAgain() {
        var detector = RxFallbackDetector()
        _ = frozen(&detector, seconds: 20, txPerTick: tick)
        for step in 1...3 {
            _ = detector.observe(id: "en0", rxBytes: UInt64(step), txBytes: 0, at: start.addingTimeInterval(Double(20 + step)))
        }
        #expect(detector.broken.isEmpty)
        let events = (0...20).compactMap { second in
            detector.observe(id: "en0", rxBytes: 3, txBytes: UInt64(second) * tick, at: start.addingTimeInterval(Double(24 + second)))
        }
        #expect(events == [.latched("en0")])
    }
}

@Suite
struct NoNettopGuardTests {
    /// nettop costs >100% CPU on macOS 27 however it is invoked, and NetFluss
    /// showed it at the top of Activity Monitor. Nothing may start it again.
    @Test func noSourceFileLaunchesNettop() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("/usr/bin/nettop") { offenders.append(url.lastPathComponent) }
        }
        #expect(scanned > 20)
        #expect(offenders.isEmpty)
    }
}
