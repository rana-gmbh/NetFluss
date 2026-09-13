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

/// App-agnostic VPN detection. Any VPN on macOS — NetFluss' own client, the
/// system IKEv2/L2TP/Cisco IPSec services, or a third-party app (Tunnelblick,
/// WireGuard, Mullvad, Tailscale, …) — ends up as a utun/ipsec/ppp/tun/tap
/// interface carrying a routable address. macOS keeps several utun interfaces
/// up for its own services (iCloud, Continuity, Back to My Mac), but those only
/// ever carry an IPv6 link-local (fe80::) address, so a routable address on a
/// tunnel interface is what distinguishes a real VPN.
enum VPNDetector {
    struct Snapshot: Equatable, Sendable {
        /// BSD name → first routable address (IPv4 preferred) of every tunnel
        /// interface that carries one.
        let tunnels: [String: String]
        /// Changes whenever the set of routable local addresses changes
        /// (VPN up/down, Wi-Fi ↔ Ethernet, new network) — used to refresh the
        /// public IP / country right away instead of waiting for the slow poll.
        let fingerprint: String

        var isVPNActive: Bool { !tunnels.isEmpty }
    }

    static func snapshot() -> Snapshot {
        var tunnelsV4: [String: String] = [:]
        var tunnelsV6: [String: String] = [:]
        var addresses: [String] = []

        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return Snapshot(tunnels: [:], fingerprint: "")
        }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current?.pointee {
            defer { current = entry.ifa_next }
            guard let sa = entry.ifa_addr,
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0,
                  (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let family = sa.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            guard isRoutable(sa) else { continue }
            guard let ip = numericHost(sa) else { continue }

            let name = String(cString: entry.ifa_name)
            addresses.append("\(name)=\(ip)")
            guard AdapterClassifier.isTunnelInterface(named: name) else { continue }
            if family == UInt8(AF_INET) {
                if tunnelsV4[name] == nil { tunnelsV4[name] = ip }
            } else if tunnelsV6[name] == nil {
                tunnelsV6[name] = ip
            }
        }

        let tunnels = tunnelsV6.merging(tunnelsV4) { _, v4 in v4 }
        return Snapshot(tunnels: tunnels, fingerprint: addresses.sorted().joined(separator: ","))
    }

    /// Excludes addresses that never indicate a real uplink: 0.0.0.0, IPv4
    /// link-local 169.254/16, and IPv6 link-local fe80::/10.
    private static func isRoutable(_ sa: UnsafeMutablePointer<sockaddr>) -> Bool {
        if sa.pointee.sa_family == UInt8(AF_INET) {
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                let addr = UInt32(bigEndian: sin.pointee.sin_addr.s_addr)
                return addr != 0 && (addr >> 16) != 0xA9FE
            }
        }
        return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
            withUnsafeBytes(of: sin6.pointee.sin6_addr) { bytes in
                let isLinkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
                let isUnspecified = bytes.allSatisfy { $0 == 0 }
                return !isLinkLocal && !isUnspecified
            }
        }
    }

    private static func numericHost(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                          &hostname, socklen_t(NI_MAXHOST),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        let ip = hostname.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return ip.isEmpty ? nil : ip
    }
}

enum CountryFlag {
    /// "DE" → "🇩🇪" via regional indicator symbols — no bundled flag assets.
    static func emoji(for code: String) -> String? {
        let code = code.uppercased()
        guard code.count == 2, code.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.isAlphabetic }) else { return nil }
        let base: UInt32 = 0x1F1E6 - 0x41 // regional indicator A
        let scalars = code.unicodeScalars.compactMap { UnicodeScalar(base + $0.value) }
        guard scalars.count == 2 else { return nil }
        return String(scalars.map { Character($0) })
    }
}
