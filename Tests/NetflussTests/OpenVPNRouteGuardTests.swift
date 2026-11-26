import XCTest
@testable import NetflussPrivilegedHelper

/// Issue #72: openvpn deletes the route of a directly connected network on
/// disconnect when the profile or the server routes that exact network.
final class OpenVPNRouteGuardTests: XCTestCase {
    /// 10.77.40.0/23 on en0, as in the issue.
    private let lan = ConnectedSubnet(network: 0x0A4D_2800, mask: 0xFFFF_FE00, interface: "en0")
    private let base = "client\ndev tun\nremote 127.0.0.1 1\n"

    private func guarded(_ config: String, connected: [ConnectedSubnet]? = nil) throws -> (text: String, notes: [String]) {
        let staged = try OpenVPNRouteGuard.guarded(Array(config.utf8), connected: connected ?? [lan])
        // Whatever the guard writes must still be a config the policy accepts.
        XCTAssertNoThrow(try OpenVPNConfigPolicy.referencedFiles(in: staged.config))
        return (String(decoding: staged.config, as: UTF8.self), staged.notes)
    }

    private func routeLines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("route ") }
    }

    func testExactMatchIsLeftOut() throws {
        let result = try guarded(base + "route 10.77.40.0 255.255.254.0 net_gateway\nroute 10.1.0.0 255.255.0.0\n")
        XCTAssertEqual(routeLines(result.text), ["route 10.1.0.0 255.255.0.0"])
        XCTAssertTrue(result.text.contains("# route left out by NetFluss"))
        XCTAssertTrue(result.notes.contains { $0.contains("10.77.40.0/23") && $0.contains("en0") && $0.contains("line 4") })
    }

    func testLargerSmallerAndOverlappingRoutesStay() throws {
        let routes = [
            "route 10.77.0.0 255.255.0.0 net_gateway",   // larger
            "route 10.77.40.0 255.255.255.0 net_gateway", // smaller, inside the LAN
            "route 10.77.41.0 255.255.255.0",             // the other half
            "route 10.77.40.5",                            // a host in the LAN
        ]
        let result = try guarded(base + routes.joined(separator: "\n") + "\n")
        XCTAssertEqual(routeLines(result.text), routes)
        XCTAssertFalse(result.notes.contains { $0.hasPrefix("Left out") })
    }

    func testRouteWithoutNetmaskIsAHostRoute() throws {
        let host = ConnectedSubnet(network: 0xC0A8_0100, mask: 0xFFFF_FF00, interface: "en1")
        let result = try guarded(base + "route 192.168.1.0\nroute 192.168.1.0 default\n", connected: [host])
        XCTAssertEqual(routeLines(result.text), ["route 192.168.1.0", "route 192.168.1.0 default"])
    }

    func testHostNamesAndKeywordsAreLeftAlone() throws {
        let result = try guarded(base + "route vpn.example.com 255.255.254.0\nroute 10.77.40.0 netmask\nroute 10.77.41.0 255.255.254.0\n")
        XCTAssertEqual(routeLines(result.text).count, 3)
    }

    func testDashDashAndSetenvOptFormsAreCaught() throws {
        let result = try guarded(base + "--route 10.77.40.0 255.255.254.0\nsetenv opt route 10.77.40.0 255.255.254.0 net_gateway\n")
        XCTAssertFalse(result.text.contains("10.77.40.0 255.255.254.0\n"))
        XCTAssertEqual(result.notes.filter { $0.hasPrefix("Left out") }.count, 2)
    }

    func testPullFiltersComeFirstWhenTheProfilePulls() throws {
        let result = try guarded(base + "pull-filter accept \"route\"\n")
        let lines = result.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("#"))
        XCTAssertEqual(lines[1], "pull-filter ignore \"route 10.77.40.0 255.255.254.0\"")
        XCTAssertEqual(lines[2], "client")
        XCTAssertTrue(result.notes.contains { $0.contains("pushes") && $0.contains("10.77.40.0/23 on en0") })
    }

    func testNoPullFiltersWithoutPull() throws {
        let result = try guarded("dev tun\nremote 127.0.0.1 1\nsecret static.key\n")
        XCTAssertFalse(result.text.contains("pull-filter"))
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testNothingConnectedChangesNothing() throws {
        let config = base + "route 10.77.40.0 255.255.254.0 net_gateway\n"
        let result = try guarded(config, connected: [])
        XCTAssertEqual(result.text, config)
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testInlineBlocksAreNotReadAsOptions() throws {
        let config = base + "<ca>\nroute 10.77.40.0 255.255.254.0\n</ca>\n"
        let result = try guarded(config)
        XCTAssertTrue(result.text.hasSuffix("<ca>\nroute 10.77.40.0 255.255.254.0\n</ca>\n"))
        XCTAssertFalse(result.notes.contains { $0.hasPrefix("Left out") })
    }

    func testCRLFAndBOMSurvive() throws {
        let bom = "\u{FEFF}"
        let config = bom + "client\r\ndev tun\r\nroute 10.77.40.0 255.255.254.0\r\nremote 127.0.0.1 1\r\n"
        let result = try guarded(config)
        XCTAssertTrue(result.text.hasPrefix(bom + "# NetFluss"))
        XCTAssertTrue(result.text.contains("# route left out by NetFluss, see its log\r\nremote"))
        XCTAssertEqual(result.text.components(separatedBy: bom).count, 2, "exactly one BOM, at the start")
    }

    func testRouteParsing() {
        func parse(_ words: String...) -> (UInt32, UInt32)? {
            OpenVPNRouteGuard.route(words.map { Array($0.utf8) }).map { ($0.network, $0.mask) }
        }
        XCTAssertTrue(parse("10.77.40.0", "255.255.254.0", "net_gateway")! == (0x0A4D_2800, 0xFFFF_FE00))
        XCTAssertTrue(parse("10.77.40.5")! == (0x0A4D_2805, .max))
        XCTAssertNil(parse("10.77.41.0", "255.255.254.0"), "host bits set: openvpn refuses it")
        XCTAssertNil(parse("net_gateway"))
        XCTAssertEqual(OpenVPNRouteGuard.dotted(0x0A4D_2800), "10.77.40.0")
    }

    /// Smoke test against this Mac: every subnet it reports is well formed.
    func testConnectedSubnetsAreWellFormed() {
        for subnet in OpenVPNRouteGuard.connectedSubnets() {
            XCTAssertEqual(subnet.network & subnet.mask, subnet.network)
            XCTAssertNotEqual(subnet.mask, .max)
            XCTAssertFalse(subnet.interface.hasPrefix("lo"))
        }
    }
}
