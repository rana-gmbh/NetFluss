import Darwin
import Foundation

/// An IPv4 network a local interface is directly connected to. macOS keeps an
/// interface route for it (`10.77.40/23  link#15  UCS  en0`).
struct ConnectedSubnet: Equatable {
    let network: UInt32
    let mask: UInt32
    let interface: String

    var cidr: String { "\(OpenVPNRouteGuard.dotted(network))/\(mask.nonzeroBitCount)" }
}

/// Keeps openvpn from deleting the route of a network the Mac is directly
/// connected to (issue #72, upstream OpenVPN/openvpn#455).
///
/// On macOS, `/sbin/route add` for a route that already exists prints "File
/// exists" but exits 0, so openvpn records the route as its own and deletes it
/// on disconnect: `route delete` takes the LAN's interface route with it, and
/// the LAN stays unreachable until the port reconnects. A route for exactly
/// such a network would fail anyway, so leaving it out changes nothing while
/// connected; on any other network it is not directly connected and stays in.
///
/// Routes in the profile are left out of the staged copy; routes the server
/// pushes are dropped by `pull-filter` lines at the top of it, where they win
/// over any of the profile's own (the first matching filter decides).
enum OpenVPNRouteGuard {
    struct Staged: Equatable {
        let config: [UInt8]
        /// One line per change, for the tunnel's log.
        let notes: [String]
    }

    /// The config openvpn should run, given the networks connected right now.
    /// Expects a config `OpenVPNConfigPolicy` accepted, and reads it the same way.
    static func guarded(_ config: [UInt8], connected: [ConnectedSubnet]) throws -> Staged {
        guard !connected.isEmpty else { return Staged(config: config, notes: []) }

        var body: [UInt8] = []
        var notes: [String] = []
        var pulls = false
        var hasBOM = false
        var openBlockClose: [UInt8]?
        var inConnection = false
        var lineNumber = 0
        var start = 0

        while start < config.count {
            let end = config[start...].firstIndex(of: 0x0A).map { $0 + 1 } ?? config.count
            var line = config[start..<end]
            start = end
            lineNumber += 1

            if lineNumber == 1, line.starts(with: OpenVPNConfigPolicy.utf8BOM) {
                hasBOM = true
                line = line.dropFirst(OpenVPNConfigPolicy.utf8BOM.count)
            }
            if let close = openBlockClose {
                if OpenVPNConfigPolicy.closes(line, tag: close) { openBlockClose = nil }
                body += line
                continue
            }
            if inConnection, OpenVPNConfigPolicy.closes(line, tag: OpenVPNConfigPolicy.connectionClose) {
                inConnection = false
                body += line
                continue
            }

            var parameters = try OpenVPNConfigPolicy.tokens(of: line, lineNumber: lineNumber)
            if let first = parameters.first, first.count >= 3, first.starts(with: [0x2D, 0x2D]) {
                parameters[0].removeFirst(2)
            }
            if parameters.count == 1, parameters[0].first == 0x3C, parameters[0].last == 0x3E {
                let tag = Array(parameters[0].dropFirst().dropLast())
                if printable(tag) == "connection" {
                    inConnection = true
                } else {
                    openBlockClose = Array("</".utf8) + tag + [0x3E]
                }
                body += line
                continue
            }

            var words = parameters[...]
            if words.count >= 3, printable(words[words.startIndex]) == "setenv",
               printable(words[words.startIndex + 1]) == "opt" {
                words = words.dropFirst(2)
            }
            let directive = words.first.map { printable($0) } ?? ""
            if directive == "client" || directive == "pull" { pulls = true }

            if directive == "route", let route = route(Array(words.dropFirst())),
               let subnet = connected.first(where: { $0.network == route.network && $0.mask == route.mask }) {
                notes.append("Left out \"route \(dotted(route.network)) \(dotted(route.mask))\" (line \(lineNumber)): "
                    + "\(subnet.cidr) is directly connected on \(subnet.interface), and OpenVPN would delete "
                    + "its route on disconnect (OpenVPN #455).")
                // A comment, not nothing, so openvpn's line numbers still match the profile.
                body += Array("# route left out by NetFluss, see its log".utf8) + lineEnding(of: line)
                continue
            }
            body += line
        }

        var header: [UInt8] = []
        if pulls {
            header += Array("# NetFluss: ignore pushed routes for directly connected networks (OpenVPN #455)\n".utf8)
            for subnet in connected {
                header += Array("pull-filter ignore \"route \(dotted(subnet.network)) \(dotted(subnet.mask))\"\n".utf8)
            }
            let list = connected.map { "\($0.cidr) on \($0.interface)" }.joined(separator: ", ")
            notes.append("Ignoring routes the server pushes for directly connected networks: \(list) (OpenVPN #455).")
        }

        // openvpn skips a BOM only at the very start of the file.
        let bom = hasBOM ? OpenVPNConfigPolicy.utf8BOM : []
        return Staged(config: bom + header + body, notes: notes)
    }

    /// `route network [netmask …]` as openvpn reads it: no netmask, or
    /// "default", is a host route. Nil for a host name, a keyword, or a network
    /// with host bits set, which openvpn turns down itself.
    static func route(_ arguments: [[UInt8]]) -> (network: UInt32, mask: UInt32)? {
        guard let first = arguments.first, let network = ipv4(first) else { return nil }
        var mask = UInt32.max
        if arguments.count >= 2, printable(arguments[1]) != "default" {
            guard let parsed = ipv4(arguments[1]) else { return nil }
            mask = parsed
        }
        guard network & mask == network else { return nil }
        return (network, mask)
    }

    /// The IPv4 subnets of the interfaces that are up, without loopback and
    /// point-to-point links (a utun's peer is a host route, not a subnet).
    static func connectedSubnets() -> [ConnectedSubnet] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var subnets: [ConnectedSubnet] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = entry.pointee.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // A contiguous mask, shorter than a host route.
            guard mask != 0, mask != .max, (~mask & (~mask &+ 1)) == 0 else { continue }
            let subnet = ConnectedSubnet(network: ip & mask, mask: mask, interface: String(cString: entry.pointee.ifa_name))
            if !subnets.contains(where: { $0.network == subnet.network && $0.mask == subnet.mask }) {
                subnets.append(subnet)
            }
        }
        return subnets
    }

    static func dotted(_ address: UInt32) -> String {
        "\(address >> 24).\(address >> 16 & 0xFF).\(address >> 8 & 0xFF).\(address & 0xFF)"
    }

    private static func ipv4(_ bytes: [UInt8]) -> UInt32? {
        guard let text = String(bytes: bytes, encoding: .ascii) else { return nil }
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func lineEnding(of line: ArraySlice<UInt8>) -> [UInt8] {
        if line.last != 0x0A { return [] }
        return line.dropLast().last == 0x0D ? [0x0D, 0x0A] : [0x0A]
    }
}
