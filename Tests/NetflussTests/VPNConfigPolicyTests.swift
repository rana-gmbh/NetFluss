import XCTest
@testable import NetflussPrivilegedHelper

/// Each attack here reached code loading or a root file primitive in the real
/// openvpn 2.6.14, or would have. Keep them when the tokenizer changes.
final class VPNConfigPolicyTests: XCTestCase {
    private let base = "client\ndev tun\nremote 127.0.0.1 1\n"
    private let plugin = "/nonexistent/x.dylib"

    private func refused(_ config: String, file: StaticString = #filePath, line: UInt = #line) {
        refused(Array(config.utf8), file: file, line: line)
    }

    private func refused(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try OpenVPNConfigPolicy.referencedFiles(in: bytes), file: file, line: line)
    }

    private func sideFiles(_ config: String, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        do {
            return try OpenVPNConfigPolicy.referencedFiles(in: Array(config.utf8))
        } catch {
            XCTFail("refused: \(error)", file: file, line: line)
            return []
        }
    }

    func testPluginIsRefusedHoweverItIsWritten() {
        refused(base + "plugin \(plugin)\n")
        refused(base + "\"plugin\" \(plugin)\n")
        refused(base + "'plugin' \(plugin)\n")
        refused(base + "plugin\u{0B}\(plugin)\n")
        refused(base + "plugin\u{0C}\(plugin)\n")
        refused(base + "--plugin \(plugin)\n")
        refused(base + "\\ plugin \(plugin)\n")
        refused(base + "setenv opt plugin \(plugin)\n")
        refused("\u{FEFF}plugin \(plugin)\n" + base)
    }

    func testWindowsLineEndingsDoNotHideALine() {
        refused("client\r\ndev tun\r\nremote 127.0.0.1 1\r\nplugin \(plugin)\r\n")
    }

    func testInvalidUTF8DoesNotDisableTheCheck() {
        refused(Array("# caf".utf8) + [0xE9, 0x0A] + Array((base + "plugin \(plugin)\n").utf8))
    }

    func testOtherWaysToLoadCodeAreRefused() {
        for directive in ["providers", "pkcs11-providers", "engine", "config"] {
            refused(base + "\(directive) \(plugin)\n")
        }
    }

    func testDirectivesThatWriteFilesAsRootAreRefused() {
        for directive in ["log", "log-append", "status", "writepid", "replay-persist", "tmp-dir", "cd",
                          "chroot", "daemon", "management", "memstats", "tls-export-cert"] {
            refused(base + "\(directive) /tmp/x\n")
        }
    }

    func testInlineBlocksCannotSmuggleOptions() {
        refused(base + "<plugin>\n\(plugin)\n</plugin>\n")
        refused(base + "<ca>\nx\n   </ca>junk\nplugin \(plugin)\n")
        refused(base + "<ca>\nplugin \(plugin)\n")
        refused(base + "<connection>\nremote 127.0.0.1 1\nplugin \(plugin)\n</connection>\n")
        refused(base + "<connection>\nremote 127.0.0.1 1\n<ca>\n</connection>\nplugin \(plugin)\n</ca>\n</connection>\n")
    }

    func testLinesOpenVPNWouldSplitAreRefused() {
        refused(base + "#" + String(repeating: "x", count: 254) + "plugin \(plugin)\n")
        refused(base + "<ca>\n" + String(repeating: "x", count: 255) + "</ca>\nplugin \(plugin)\n</ca>\n")
    }

    func testNULIsRefused() {
        refused(Array(base.utf8) + [0x23, 0x00, 0x0A] + Array("plugin \(plugin)\n".utf8))
    }

    func testFilesMustStayInsideTheProfile() {
        refused(base + "auth-user-pass /etc/master.passwd\n")
        refused(base + "ca ../../../../etc/hosts\n")
        refused(base + "crl-verify crls dir\n")
    }

    func testCarriageReturnIsNotALineBreak() {
        // openvpn reads this whole line as one comment.
        XCTAssertEqual(sideFiles(base + "#x\rplugin \(plugin)\n"), [])
    }

    func testTypicalProviderConfigPasses() {
        let config = """
        # Provider boilerplate
        client
        dev tun
        proto udp
        remote vpn.example.com 1194
        resolv-retry infinite
        nobind
        persist-key
        persist-tun
        remote-cert-tls server
        data-ciphers AES-256-GCM:AES-128-GCM
        verb 3
        auth-user-pass
        script-security 2
        up /etc/openvpn/update-resolv-conf
        down /etc/openvpn/update-resolv-conf
        setenv CLIENT_CERT 0
        setenv opt block-outside-dns
        <ca>
        -----BEGIN CERTIFICATE-----
        plugin /not/an/option/just/data
        -----END CERTIFICATE-----
        </ca>
        key-direction 1

        """
        XCTAssertEqual(sideFiles(config), [])
    }

    func testSideFilesAreListed() {
        let config = "client\r\ndev tun\r\nremote a.example 443 tcp\r\nca ca.crt\r\ncert sub/client.crt\r\n"
            + "key client.key\r\ntls-auth ta.key 1\r\nauth-user-pass creds.txt\r\nhttp-proxy p 8080 proxy.auth\r\n"
        XCTAssertEqual(sideFiles(config), ["ca.crt", "sub/client.crt", "client.key", "ta.key", "creds.txt", "proxy.auth"])
    }

    func testKeywordsAreNotFiles() {
        XCTAssertEqual(sideFiles(base + "dh none\nhttp-proxy p 8080 auto\nauth-user-pass stdin\n"), [])
    }

    func testConnectionBlocksAndNonUTF8CommentsPass() {
        XCTAssertEqual(sideFiles("client\ndev tun\n<connection>\nremote a.example\n</connection>\n"), [])
        XCTAssertNoThrow(try OpenVPNConfigPolicy.referencedFiles(in: Array("# f".utf8) + [0xFC, 0x0A] + Array(base.utf8)))
    }
}

final class WireGuardConfigPolicyTests: XCTestCase {
    private let interface = "[Interface]\nPrivateKey = aaa=\nAddress = 10.0.0.2/32\n"
    private let peer = "[Peer]\nPublicKey = bbb=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:51820\n"

    func testHooksAreRefused() {
        for hook in ["PostUp = id", "postup=id", "  PreUp\t=\tid", "PreDown = id # note", "PostDown = id"] {
            XCTAssertThrowsError(try WireGuardConfigPolicy.validate(Array((interface + hook + "\n" + peer).utf8)), hook)
        }
    }

    func testHookInAWindowsFormatFileIsRefused() {
        let config = "[Interface]\r\nPrivateKey = a=\r\nPostDown = id\r\n[Peer]\r\nPublicKey = b\r\n"
        XCTAssertThrowsError(try WireGuardConfigPolicy.validate(Array(config.utf8)))
    }

    func testNULIsRefusedBecauseBashDropsIt() {
        XCTAssertThrowsError(try WireGuardConfigPolicy.validate(Array("[Interface]\nPost".utf8) + [0] + Array("Up = id\n".utf8)))
    }

    func testUnknownKeysAndSectionsAreRefused() {
        XCTAssertThrowsError(try WireGuardConfigPolicy.validate(Array((interface + "Bogus = 1\n").utf8)))
        XCTAssertThrowsError(try WireGuardConfigPolicy.validate(Array("[Interface ]\nPostUp = id\n".utf8)))
    }

    func testTypicalConfigsPass() throws {
        try WireGuardConfigPolicy.validate(Array(("# Provider\n" + interface + "DNS = 1.1.1.1\nMTU = 1420\n\n" + peer
            + "PersistentKeepalive = 25 # keep\nPresharedKey = c=\n").utf8))
        try WireGuardConfigPolicy.validate(Array((interface + peer).replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }
}

final class HelperInputPolicyTests: XCTestCase {
    func testInterfaceNames() {
        XCTAssertTrue(HelperInputPolicy.isInterfaceName("en0"))
        XCTAssertTrue(HelperInputPolicy.isInterfaceName("utun12"))
        for bad in ["", "en", "0", "-a", "en0 down", "en0;id", "abcdefghijklmnop1"] {
            XCTAssertFalse(HelperInputPolicy.isInterfaceName(bad), bad)
        }
    }

    func testServiceNames() {
        XCTAssertTrue(HelperInputPolicy.isServiceName("Thunderbolt Ethernet Slot 1"))
        XCTAssertTrue(HelperInputPolicy.isServiceName("Büro-VPN"))
        XCTAssertFalse(HelperInputPolicy.isServiceName(""))
        XCTAssertFalse(HelperInputPolicy.isServiceName("-setv6off"))
        XCTAssertFalse(HelperInputPolicy.isServiceName("a\nb"))
    }

    func testIPAddresses() {
        for good in ["1.1.1.1", "2606:4700:4700::1111"] { XCTAssertTrue(HelperInputPolicy.isIPAddress(good), good) }
        for bad in ["", "1.1.1", "1.1.1.1.1", "[::1]", "one.one", "-x"] { XCTAssertFalse(HelperInputPolicy.isIPAddress(bad), bad) }
    }

    func testWifiSettings() {
        XCTAssertTrue(HelperInputPolicy.isSSID("Café Wi-Fi"))
        XCTAssertFalse(HelperInputPolicy.isSSID(String(repeating: "x", count: 33)))
        XCTAssertTrue(HelperInputPolicy.isWifiSecurityType("WPA2"))
        XCTAssertFalse(HelperInputPolicy.isWifiSecurityType("wpa2 -x"))
    }

    func testManagementSocketPath() {
        XCTAssertTrue(HelperInputPolicy.isManagementSocketPath("/tmp/netfluss-vpn-A1B2C3D4.sock"))
        for bad in ["/tmp/x.sock", "/etc/netfluss-vpn-A1B2C3D4.sock", "/tmp/netfluss-vpn-../../etc/x.sock", "/tmp/netfluss-vpn-.sock"] {
            XCTAssertFalse(HelperInputPolicy.isManagementSocketPath(bad), bad)
        }
    }

    func testUserNames() {
        XCTAssertTrue(HelperInputPolicy.isUserName("robert.rudolph"))
        XCTAssertFalse(HelperInputPolicy.isUserName("-x"))
        XCTAssertFalse(HelperInputPolicy.isUserName("a b"))
    }
}
