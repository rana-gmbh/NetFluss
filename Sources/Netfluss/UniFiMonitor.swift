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

        for urlString in loginPaths {
            guard let url = URL(string: urlString) else { continue }

            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: String] = ["username": username, "password": password]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let session = Self.makeSession()
            do {
                let (_, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { continue }

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
            } catch {
                continue
            }
        }

        throw UniFiError.authFailed
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

    // MARK: - Parsing

    private static func parseDeviceStats(_ data: Data) throws -> UniFiBandwidth {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["data"] as? [[String: Any]] else {
            throw UniFiError.parseError
        }

        // Find the gateway device (type: ugw, udm, or uxg)
        let gatewayTypes: Set<String> = ["ugw", "udm", "uxg"]
        guard let gateway = devices.first(where: { device in
            if let type = device["type"] as? String { return gatewayTypes.contains(type) }
            return false
        }) else {
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

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config, delegate: InsecureTLSDelegate.shared, delegateQueue: nil)
    }

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
}

// MARK: - Insecure TLS Delegate (UniFi uses self-signed certs)

final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
    static let shared = InsecureTLSDelegate()

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
