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
import CryptoKit

/// Real Defguard control client, implemented in pure Swift over the proxy's
/// public REST API — no gRPC, no bundled binary (issue #51).
///
/// The Defguard proxy ("Edge") exposes JSON REST endpoints the desktop client
/// uses (the gRPC service is core↔proxy only):
///   POST {proxy}/api/v1/enrollment/start        {token}
///   POST {proxy}/api/v1/enrollment/create_device {name, pubkey, token} → DeviceConfigResponse
///   POST {proxy}/api/v1/client-mfa/start         {location_id, pubkey, method} → {token, challenge}
///   POST {proxy}/api/v1/client-mfa/finish        {token, code}            → {preshared_key}
/// Field names mirror DefGuard/proto `common/client_types.proto`.
///
/// UNVALIDATED against a live server yet (see Docs/Defguard.md) — testing is via
/// the reporter's instance. Known things to confirm there:
///  - `MfaMethod` JSON encoding (integer `0` vs the string "TOTP").
///  - Whether a session cookie from `/start` is required by `/create_device`
///    (URLSession keeps cookies by default, so this should already work).
///  - Whether first-time enrollment also needs `activate_user`.
struct DefguardRESTClient: DefguardControlClient {
    /// A session that persists cookies across the enrollment calls.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = HTTPCookieStorage()
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    /// TOTP as sent in `ClientMfaStartRequest.method`. Encoded as the integer the
    /// proto assigns (TOTP = 0); flip to the string form if the server rejects it.
    private static let totpMethod = 0

    // MARK: DefguardControlClient

    func enroll(instanceURL: String, token: String, deviceName: String) async throws -> DefguardEnrollmentResult {
        let base = Self.apiBase(instanceURL)

        // 1) Start enrollment (also establishes the session cookie).
        _ = try? await post(base, "enrollment/start", body: ["token": token], as: EnrollmentStartDTO.self)

        // 2) Generate this device's WireGuard keypair (Curve25519, base64 — the
        //    WireGuard key format). The private key never leaves the Keychain.
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let privateKey = priv.rawRepresentation.base64EncodedString()
        let publicKey = priv.publicKey.rawRepresentation.base64EncodedString()

        // 3) Register the device and receive its per-location configs.
        let device: DeviceConfigDTO
        do {
            device = try await post(base, "enrollment/create_device",
                                    body: ["name": deviceName, "pubkey": publicKey, "token": token],
                                    as: DeviceConfigDTO.self)
        } catch let e as DefguardError {
            throw e
        } catch {
            throw DefguardError.enrollmentFailed(error.localizedDescription)
        }

        let instance = DefguardInstance(
            name: device.instance?.name ?? URL(string: instanceURL)?.host ?? "Defguard",
            instanceURL: instanceURL,
            proxyURL: base.absoluteString,
            devicePublicKey: publicKey,
            keychainAccount: "defguard-device-\(UUID().uuidString.prefix(12))"
        )
        let locations = (device.configs ?? []).map { $0.asLocation() }
        return DefguardEnrollmentResult(instance: instance, devicePrivateKey: privateKey,
                                        devicePublicKey: publicKey, locations: locations)
    }

    func startMFA(instance: DefguardInstance, location: DefguardLocation,
                  method: DefguardMFAMethod) async throws -> DefguardMFAChallenge {
        let base = Self.apiBase(instance.proxyURL)
        do {
            let resp = try await post(base, "client-mfa/start",
                                      body: ["location_id": location.networkID,
                                             "pubkey": instance.devicePublicKey,
                                             "method": Self.totpMethod] as [String: Any],
                                      as: ClientMfaStartDTO.self)
            return DefguardMFAChallenge(method: .totp, token: resp.token)
        } catch let e as DefguardError {
            throw e
        } catch {
            throw DefguardError.mfaFailed(error.localizedDescription)
        }
    }

    func finishMFA(instance: DefguardInstance, location: DefguardLocation,
                   challenge: DefguardMFAChallenge, code: String) async throws -> DefguardMFAResult {
        let base = Self.apiBase(instance.proxyURL)
        guard let token = challenge.token else { throw DefguardError.mfaFailed("missing MFA session token") }
        do {
            let resp = try await post(base, "client-mfa/finish",
                                      body: ["token": token, "code": code],
                                      as: ClientMfaFinishDTO.self)
            return DefguardMFAResult(presharedKey: resp.preshared_key, ttlSeconds: nil)
        } catch let e as DefguardError {
            throw e
        } catch {
            throw DefguardError.invalidCode
        }
    }

    // MARK: - HTTP

    /// `<scheme>://<host>/api/v1/` derived from a pasted instance/proxy URL.
    private static func apiBase(_ raw: String) -> URL {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "https://" + s }
        var base = URL(string: s) ?? URL(string: "https://\(s)")!
        // Keep only scheme+host(+port); append the versioned API path.
        if var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            comps.path = "/api/v1"
            comps.query = nil
            comps.fragment = nil
            base = comps.url ?? base
        }
        return base
    }

    private func post<T: Decodable>(_ base: URL, _ path: String, body: [String: Any], as: T.Type) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw DefguardError.enrollmentFailed("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8).map { $0.prefix(200) } ?? ""
            throw DefguardError.enrollmentFailed("HTTP \(http.statusCode) \(detail)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DefguardError.enrollmentFailed("unexpected response: \(error.localizedDescription)")
        }
    }
}

// MARK: - Wire DTOs (subset of DefGuard/proto client_types.proto)

private struct EnrollmentStartDTO: Decodable {
    var instance: InstanceInfoDTO?
    var deadline_timestamp: Int64?
}

private struct InstanceInfoDTO: Decodable {
    var name: String?
    var id: String?
    var proxy_url: String?
}

private struct DeviceConfigDTO: Decodable {
    var configs: [LocationConfigDTO]?
    var instance: InstanceInfoDTO?
    var token: String?
}

private struct LocationConfigDTO: Decodable {
    var network_id: Int
    var network_name: String
    var endpoint: String
    var assigned_ip: String
    var pubkey: String                // server (peer) public key
    var allowed_ips: String           // comma/space separated
    var dns: String?
    var keepalive_interval: Int?
    var location_mfa_mode: String?    // "disabled" | "internal" | "external"

    func asLocation() -> DefguardLocation {
        DefguardLocation(
            networkID: network_id,
            name: network_name,
            assignedIP: assigned_ip,
            serverPublicKey: pubkey,
            endpoint: endpoint,
            allowedIPs: allowed_ips.split { $0 == "," || $0 == " " }.map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            dns: dns.map { $0.split { $0 == "," || $0 == " " }.map(String.init) } ?? [],
            keepaliveInterval: keepalive_interval ?? 25,
            mfaMode: DefguardMFAMode(rawValue: (location_mfa_mode ?? "disabled").lowercased()) ?? .internal
        )
    }
}

private struct ClientMfaStartDTO: Decodable {
    var token: String
    var challenge: String?
}

private struct ClientMfaFinishDTO: Decodable {
    var preshared_key: String
    var token: String?
}
