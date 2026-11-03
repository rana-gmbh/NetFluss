import XCTest
import Darwin
@testable import Netfluss
@testable import NetflussPrivilegedHelper

/// Issue #68: a disconnected VPN whose tunnel stayed up. These pin how the
/// helper finds its tunnels again after a restart, how system VPN services
/// are identified, and how the route card names NetFluss's own tunnel.
final class VPNTunnelTrackingTests: XCTestCase {
    private let openvpnPath = "/Applications/NetFluss.app/Contents/Library/VPN/openvpn"

    private func record(startTime: UInt64? = 42) -> TunnelRecord {
        TunnelRecord(kind: .openVPN, handle: "4242", owner: "robert", startTime: startTime,
                     stagedPath: "/var/run/netfluss/ovpn-1")
    }

    func testARecordSurvivesARoundTrip() throws {
        let data = try XCTUnwrap(record().encoded())
        XCTAssertEqual(TunnelRecord.decode(data), record())
    }

    func testAHandleCannotLeaveTheRecordFolder() {
        XCTAssertEqual(TunnelRecord.fileName(for: "4242"), "tunnel-4242.json")
        XCTAssertEqual(TunnelRecord.fileName(for: "utun8"), "tunnel-utun8.json")
        XCTAssertNil(TunnelRecord.fileName(for: "../etc"))
        XCTAssertNil(TunnelRecord.fileName(for: ""))
        var bad = record()
        bad.handle = "../x"
        XCTAssertNil(bad.encoded().flatMap(TunnelRecord.decode))
    }

    /// A reused pid must never be signalled: it has to be the same process,
    /// started at the recorded time, running the bundled binary.
    func testOnlyTheRecordedOpenVPNMatches() {
        XCTAssertTrue(record().describesOpenVPN(processPath: openvpnPath, startTime: 42))
        XCTAssertFalse(record().describesOpenVPN(processPath: openvpnPath, startTime: 43))
        XCTAssertFalse(record().describesOpenVPN(processPath: "/usr/sbin/openvpn", startTime: 42))
        XCTAssertFalse(record().describesOpenVPN(processPath: "/Applications/Other.app/Contents/Library/VPN/zsh", startTime: 42))
        XCTAssertFalse(record().describesOpenVPN(processPath: nil, startTime: 42))
        XCTAssertFalse(record(startTime: nil).describesOpenVPN(processPath: openvpnPath, startTime: 42))
    }

    func testProcessFactsForThisProcess() {
        let pid = getpid()
        XCTAssertTrue(ProcessInfoLookup.isAlive(pid))
        XCTAssertNotNil(ProcessInfoLookup.startTime(of: pid))
        XCTAssertEqual(ProcessInfoLookup.startTime(of: pid), ProcessInfoLookup.startTime(of: pid))
        XCTAssertNotNil(ProcessInfoLookup.executablePath(of: pid))
    }

    func testServiceIDFromScutilList() {
        let line = #"* (Disconnected)   6D2F1A3B-9C4E-4F5A-8B7C-0D1E2F3A4B5C IPSec              "#
        XCTAssertEqual(NativeVPN.serviceID(inListLine: line), "6D2F1A3B-9C4E-4F5A-8B7C-0D1E2F3A4B5C")
        XCTAssertNil(NativeVPN.serviceID(inListLine: "* (Connected) IPSec "))
    }

    func testTheRouteCardNamesNetFlussTunnel() {
        let tunnels = [(id: "utun8", displayName: "VPN (utun8)")]
        XCTAssertEqual(VPNRouteLabel.make(tunnels: tunnels, own: ("utun8", "MARS")).label, "MARS")
        XCTAssertEqual(VPNRouteLabel.make(tunnels: tunnels, own: ("utun8", "MARS")).detail, "utun8")
        XCTAssertEqual(VPNRouteLabel.make(tunnels: tunnels, own: nil).label, "VPN (utun8)")
    }

    func testOtherTunnelsKeepTheirInterfaceName() {
        let tunnels = [(id: "utun8", displayName: "VPN"), (id: "utun9", displayName: "VPN")]
        XCTAssertEqual(VPNRouteLabel.make(tunnels: tunnels, own: ("utun8", "MARS")).detail, "MARS, utun9")
        XCTAssertEqual(VPNRouteLabel.make(tunnels: tunnels, own: nil).detail, "utun8, utun9")
    }
}
