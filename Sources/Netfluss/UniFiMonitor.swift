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
import Security

struct UniFiBandwidth: Equatable, Sendable {
    let rxRateBps: Double
    let txRateBps: Double
    let maxDownstreamMbps: UInt64
    let maxUpstreamMbps: UInt64
}

enum UniFiError: Error {
    case invalidURL
    case authFailed
    case twoFactorRequired
    case noGatewayFound
    case requestFailed
    case parseError
}

enum UniFiMonitor {

    // MARK: - Session Management

    private static var sessionCookie: String?
    private static var sessionHost: String?

    /// Authenticate with the UniFi controller and store the session cookie.
    static func login(host: String, username: String, password: String) async throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UniFiError.invalidURL }

        // Try UniFi OS (UDM) endpoint first, fall back to legacy controller
        let hasPort = trimmed.contains(":")
        var loginPaths = ["https://\(trimmed)/api/auth/login"]
        if !hasPort {
            loginPaths.append("https://\(trimmed):8443/api/login")
        }

        var sawResponse = false
        var twoFactorRequired = false

        for urlString in loginPaths {
            guard let url = URL(string: urlString) else { continue }

            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: String] = ["username": username, "password": password]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let session = Self.makeSession()
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { continue }
                sawResponse = true

                if httpResponse.statusCode == 200 {
                    // Extract session cookie (TOKEN for UniFi OS, unifises for legacy)
                    if let fields = httpResponse.allHeaderFields as? [String: String],
                       let responseURL = httpResponse.url {
                        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: responseURL)
                        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                        if !cookieHeader.isEmpty {
                            sessionCookie = cookieHeader
                            sessionHost = trimmed
                            return
                        }
                    }
                }

                // UniFi OS answers a correct password with HTTP 499 (and/or a
                // `{"required":"2fa"}` body) when the account has 2FA enabled.
                if httpResponse.statusCode == 499 {
                    twoFactorRequired = true
                } else if let bodyJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let required = bodyJSON["required"] as? String,
                          required.lowercased().contains("2fa") || required.lowercased().contains("mfa") {
                    twoFactorRequired = true
                }
            } catch {
                continue
            }
        }

        if twoFactorRequired { throw UniFiError.twoFactorRequired }
        // If we never got any HTTP response, the controller was unreachable
        // rather than the credentials being wrong.
        throw sawResponse ? UniFiError.authFailed : UniFiError.requestFailed
    }

    /// Fetch real-time WAN bandwidth from the UniFi gateway device.
    static func fetchBandwidth(host: String, username: String, password: String) async throws -> UniFiBandwidth {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UniFiError.invalidURL }

        // Login if needed or host changed
        if sessionCookie == nil || sessionHost != trimmed {
            try await login(host: trimmed, username: username, password: password)
        }

        // Try UniFi OS path first, then legacy
        let hasPort = trimmed.contains(":")
        var apiPaths = ["https://\(trimmed)/proxy/network/api/s/default/stat/device"]
        if !hasPort {
            apiPaths.append("https://\(trimmed):8443/api/s/default/stat/device")
        }

        for urlString in apiPaths {
            guard let url = URL(string: urlString) else { continue }

            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")

            let session = Self.makeSession()
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { continue }

                if httpResponse.statusCode == 401 {
                    // Session expired — re-login and retry once
                    sessionCookie = nil
                    try await login(host: trimmed, username: username, password: password)
                    var retryRequest = request
                    retryRequest.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
                    let (retryData, retryResponse) = try await session.data(for: retryRequest)
                    guard let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 200 else {
                        continue
                    }
                    return try parseDeviceStats(retryData)
                }

                if httpResponse.statusCode == 200 {
                    return try parseDeviceStats(data)
                }
            } catch let error as UniFiError {
                throw error
            } catch {
                continue
            }
        }

        throw UniFiError.requestFailed
    }

    /// Fetch real-time WAN bandwidth using a UniFi Network API key.
    ///
    /// API keys are created in the UniFi Network application under
    /// Settings → Control Plane → Integrations. They authenticate via the
    /// `X-API-KEY` header and sidestep passwords and 2FA entirely, which makes
    /// them the right fit for a background monitor.
    static func fetchBandwidth(host: String, apiKey: String) async throws -> UniFiBandwidth {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UniFiError.invalidURL }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw UniFiError.authFailed }

        let hasPort = trimmed.contains(":")
        var apiPaths = ["https://\(trimmed)/proxy/network/api/s/default/stat/device"]
        if !hasPort {
            apiPaths.append("https://\(trimmed):8443/api/s/default/stat/device")
        }

        var sawAuthFailure = false

        for urlString in apiPaths {
            guard let url = URL(string: urlString) else { continue }

            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue(key, forHTTPHeaderField: "X-API-KEY")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let session = Self.makeSession()
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { continue }

                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    sawAuthFailure = true
                    continue
                }
                if httpResponse.statusCode == 200 {
                    return try parseDeviceStats(data)
                }
            } catch let error as UniFiError {
                throw error
            } catch {
                continue
            }
        }

        if sawAuthFailure { throw UniFiError.authFailed }
        throw UniFiError.requestFailed
    }

    // MARK: - Parsing

    private static func parseDeviceStats(_ data: Data) throws -> UniFiBandwidth {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["data"] as? [[String: Any]] else {
            throw UniFiError.parseError
        }

        // Find the gateway device by type. Known gateway/console types:
        //   ugw (USG), udm (Dream Machine), udr (Dream Router),
        //   uxg (Next-gen Gateway), ucg (Cloud Gateway), udw (Dream Wall).
        let gatewayTypes: Set<String> = ["ugw", "udm", "udr", "uxg", "ucg", "udw"]
        let gateway = devices.first(where: { device in
            if let type = device["type"] as? String { return gatewayTypes.contains(type) }
            return false
        })
        // Fallback for unrecognized/future console types: the gateway is the
        // device that reports a WAN uplink (APs/switches do not carry `wan1`).
        ?? devices.first(where: { $0["wan1"] is [String: Any] })

        guard let gateway else {
            throw UniFiError.noGatewayFound
        }

        // Try wan1 first, then uplink
        let wan = (gateway["wan1"] as? [String: Any]) ?? (gateway["uplink"] as? [String: Any]) ?? [:]

        let rxRate = (wan["rx_bytes-r"] as? Double) ?? (wan["rx_bytes-r"] as? Int).map(Double.init) ?? 0
        let txRate = (wan["tx_bytes-r"] as? Double) ?? (wan["tx_bytes-r"] as? Int).map(Double.init) ?? 0
        let maxSpeed = (wan["max_speed"] as? UInt64) ?? (wan["speed"] as? UInt64) ?? 0

        return UniFiBandwidth(
            rxRateBps: rxRate,
            txRateBps: txRate,
            maxDownstreamMbps: maxSpeed,
            maxUpstreamMbps: maxSpeed
        )
    }

    // MARK: - TLS (self-signed cert support)

    /// One reused session: enables HTTP keep-alive + TLS resumption across the
    /// 5-second polls (was creating a fresh ephemeral session — and full TLS
    /// handshake — per request) and pins the router's certificate (TOFU).
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config, delegate: PinningTLSDelegate.shared, delegateQueue: nil)
    }()

    private static func makeSession() -> URLSession { session }

    // MARK: - Keychain Helpers

    static func saveCredentials(host: String, username: String, password: String) {
        let service = "com.local.netfluss.unifi"
        let account = host

        // Encode username:password
        let value = "\(username)\n\(password)"
        guard let data = value.data(using: .utf8) else { return }

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func loadCredentials(host: String) -> (username: String, password: String)? {
        let service = "com.local.netfluss.unifi"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }

        let parts = value.split(separator: "\n", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (username: String(parts[0]), password: String(parts[1]))
    }

    static func deleteCredentials(host: String) {
        let service = "com.local.netfluss.unifi"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - API Key (Keychain)

    private static let apiKeyService = "com.local.netfluss.unifi.apikey"

    static func saveAPIKey(host: String, apiKey: String) {
        guard let data = apiKey.data(using: .utf8) else { return }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyService,
            kSecAttrAccount as String: host
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyService,
            kSecAttrAccount as String: host,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func loadAPIKey(host: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyService,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func deleteAPIKey(host: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyService,
            kSecAttrAccount as String: host
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// Router TLS trust is handled by PinningTLSDelegate in RouterTLS.swift (TOFU
// certificate pinning), shared by the UniFi/OpenWRT/OPNsense monitors.
