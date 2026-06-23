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

/// Builds a `.mobileconfig` for an IKEv2 VPN with username/password (EAP) auth,
/// optionally bundling a CA certificate to trust. The user installs it (macOS
/// prompts in System Settings); the resulting service is then controllable via
/// `NativeVPN`. This avoids needing any Network Extension entitlement.
enum IKEv2ProfileGenerator {
    struct Input {
        var name: String
        var server: String          // RemoteAddress (IP or hostname)
        var remoteID: String        // RemoteIdentifier (server cert SAN)
        var username: String
        var password: String
        var caCertificate: Data?    // optional CA, PEM or DER
    }

    static func makeMobileconfig(_ input: Input) throws -> URL {
        let vpnUUID = UUID().uuidString
        let topUUID = UUID().uuidString

        let ikev2: [String: Any] = [
            "RemoteAddress": input.server,
            "RemoteIdentifier": input.remoteID,
            "LocalIdentifier": input.username,
            "AuthenticationMethod": "None",     // server cert + EAP user auth
            "ExtendedAuthEnabled": 1,
            "AuthName": input.username,
            "AuthPassword": input.password,
            "DeadPeerDetectionRate": "Medium"
        ]

        var payloads: [[String: Any]] = []

        if let cert = input.caCertificate, let der = derCertificate(from: cert) {
            let certUUID = UUID().uuidString
            payloads.append([
                "PayloadType": "com.apple.security.root",
                "PayloadVersion": 1,
                "PayloadIdentifier": "com.local.netfluss.ca.\(certUUID)",
                "PayloadUUID": certUUID,
                "PayloadDisplayName": "\(input.name) CA",
                "PayloadContent": der
            ])
        }

        payloads.append([
            "PayloadType": "com.apple.vpn.managed",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.local.netfluss.vpn.\(vpnUUID)",
            "PayloadUUID": vpnUUID,
            "PayloadDisplayName": input.name,
            "UserDefinedName": input.name,
            "VPNType": "IKEv2",
            "IKEv2": ikev2
        ])

        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.local.netfluss.\(topUUID)",
            "PayloadUUID": topUUID,
            "PayloadDisplayName": input.name,
            "PayloadDescription": "IKEv2 VPN added via NetFluss",
            "PayloadContent": payloads
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        let safe = input.name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "-")
        // Write to Downloads (a stable, user-visible location) — the profile
        // installer can miss files in the per-app temp directory.
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("netfluss-\(safe.isEmpty ? "vpn" : safe).mobileconfig")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Accept a certificate as PEM or DER and return DER bytes.
    private static func derCertificate(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8),
              text.contains("-----BEGIN CERTIFICATE-----") else {
            return data   // already DER
        }
        let base64 = text
            .components(separatedBy: "-----BEGIN CERTIFICATE-----").last?
            .components(separatedBy: "-----END CERTIFICATE-----").first?
            .components(separatedBy: .whitespacesAndNewlines).joined() ?? ""
        return Data(base64Encoded: base64)
    }
}
