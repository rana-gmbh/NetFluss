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

struct OPNsenseBandwidth: Equatable, Sendable {
    let rxRateBps: Double
    let txRateBps: Double
    let linkSpeedMbps: UInt64
}

struct OPNsenseSample: Equatable, Sendable {
    let rxBytes: UInt64
    let txBytes: UInt64
    let linkSpeedMbps: UInt64
    let timestamp: Date
    let interfaceID: String
}

enum OPNsenseError: Error {
    case invalidURL
    case authFailed
    case httpStatus(Int)
    case requestFailed
    case parseError
    case noWANInterface
}

enum OPNsenseMonitor {
    // MARK: - Session Management

    private static var sessionHost: String?
    private static var sessionBaseURL: URL?

    // MARK: - Public API

    /// Validate host and remember the normalized API base URL.
    static func login(host: String, apiKey: String, apiSecret: String) async throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OPNsenseError.invalidURL }

        sessionHost = nil
        sessionBaseURL = nil

        var lastError: Error = OPNsenseError.requestFailed
        for baseURL in try candidateBaseURLs(for: trimmed) {
            do {
                // Simple auth check against a lightweight GET endpoint.
                _ = try await getJSON(
                    baseURL: baseURL,
                    path: "/api/diagnostics/traffic/interface",
                    apiKey: apiKey,
                    apiSecret: apiSecret
                )

                sessionHost = trimmed
                sessionBaseURL = baseURL
                return
            } catch OPNsenseError.authFailed {
                throw OPNsenseError.authFailed
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    /// Discover the WAN-like interface identifier.
    ///
    /// OPNsense exposes a traffic interface endpoint, but public docs do not
    /// fully document the exact response shape. This implementation is tolerant:
    /// it accepts either:
    /// - { "interfaces": { "wan": "WAN1_FIBRE", ... } }
    /// - { "interfaces": ["wan", "opt1", ...] }
    /// - { "interfaces": [{ "id": "wan", "name": "WAN1_FIBRE" }, ...] }
    ///
    /// Prefer a caller-supplied override if you already know the interface ID.
    static func discoverWANInterface(
        host: String,
        apiKey: String,
        apiSecret: String
    ) async throws -> String {
        let baseURL = try requireSessionBaseURL(for: host)

        let json = try await getJSON(
            baseURL: baseURL,
            path: "/api/diagnostics/traffic/interface",
            apiKey: apiKey,
            apiSecret: apiSecret
        )

        guard let interfaces = json["interfaces"] as? [String: Any] else {
            throw OPNsenseError.parseError
        }

        // OPNsense uses interface keys like "wan", "lan", "opt1"
        // Try to pick the WAN interface
        if let wanID = pickWANInterfaceID(from: Array(interfaces.keys)) {
            return wanID
        }

        throw OPNsenseError.noWANInterface
    }

    /// Pick WAN interface from a list of interface IDs like ["wan", "lan", "opt1"].
    private static func pickWANInterfaceID(from ids: [String]) -> String? {
        // Prefer exact "wan"
        if let exact = ids.first(where: { $0.lowercased() == "wan" }) {
            return exact
        }
        // Otherwise look for anything starting with "wan"
        if let prefixed = ids.first(where: { $0.lowercased().hasPrefix("wan") }) {
            return prefixed
        }
        // Fallback: return first (shouldn't happen if we have a WAN)
        return ids.first
    }

    /// Fetch bandwidth from the traffic interface endpoint.
    /// This is simpler than using get_interface_statistics — it returns
    /// interface data keyed by interface name (wan, lan, opt1) with byte counters
    /// and link rate.
    static func fetchInterfaceStats(
        host: String,
        apiKey: String,
        apiSecret: String,
        interfaceID: String
    ) async throws -> OPNsenseSample {
        let baseURL = try requireSessionBaseURL(for: host)

        let json = try await getJSON(
            baseURL: baseURL,
            path: "/api/diagnostics/traffic/interface",
            apiKey: apiKey,
            apiSecret: apiSecret
        )

        guard let interfacesDict = json["interfaces"] as? [String: Any] else {
            throw OPNsenseError.parseError
        }

        // interfaceID is like "wan", "lan", "opt1"
        guard let ifaceData = interfacesDict[interfaceID] as? [String: Any] else {
            print("OPNsense: Interface '\(interfaceID)' not found. Available: \(interfacesDict.keys.joined(separator: ", "))")
            throw OPNsenseError.noWANInterface
        }

        let rxBytes = uint64Value(ifaceData["bytes received"])
        let txBytes = uint64Value(ifaceData["bytes transmitted"])

        // Parse "line rate" like "1000000000 bit/s" to Mbps
        let linkSpeedMbps = parseLineRate(ifaceData["line rate"])

        return OPNsenseSample(
            rxBytes: rxBytes,
            txBytes: txBytes,
            linkSpeedMbps: linkSpeedMbps,
            timestamp: Date(),
            interfaceID: interfaceID
        )
    }

    /// Parse line rate string like "1000000000 bit/s" to Mbps.
    private static func parseLineRate(_ any: Any?) -> UInt64 {
        guard let rateStr = any as? String else { return 0 }
        // Extract numeric part before space or "bit/s"
        let components = rateStr.split(separator: " ")
        guard let firstPart = components.first, let bits = UInt64(firstPart) else { return 0 }
        // Convert bits to Mbps (divide by 1,000,000)
        return bits / 1_000_000
    }

    /// High-level API matching your OpenWRT version.
    static func fetchSample(
        host: String,
        apiKey: String,
        apiSecret: String,
        preferredInterfaceID: String? = nil
    ) async throws -> OPNsenseSample {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OPNsenseError.invalidURL }

        if sessionHost == nil || sessionHost != trimmed || sessionBaseURL == nil {
            try await login(host: trimmed, apiKey: apiKey, apiSecret: apiSecret)
        }

        let interfaceID: String
        if let preferredInterfaceID, !preferredInterfaceID.isEmpty {
            interfaceID = preferredInterfaceID
        } else {
            interfaceID = try await discoverWANInterface(
                host: trimmed,
                apiKey: apiKey,
                apiSecret: apiSecret
            )
        }

        do {
            return try await fetchInterfaceStats(
                host: trimmed,
                apiKey: apiKey,
                apiSecret: apiSecret,
                interfaceID: interfaceID
            )
        } catch OPNsenseError.authFailed {
            try await login(host: trimmed, apiKey: apiKey, apiSecret: apiSecret)
            return try await fetchInterfaceStats(
                host: trimmed,
                apiKey: apiKey,
                apiSecret: apiSecret,
                interfaceID: interfaceID
            )
        }
    }

    /// Same client-side rate calculation model as your OpenWRT code.
    static func bandwidth(from old: OPNsenseSample, to new: OPNsenseSample) -> OPNsenseBandwidth? {
        let dt = new.timestamp.timeIntervalSince(old.timestamp)
        guard dt > 0 else { return nil }

        let rxDelta = new.rxBytes >= old.rxBytes ? new.rxBytes - old.rxBytes : 0
        let txDelta = new.txBytes >= old.txBytes ? new.txBytes - old.txBytes : 0

        return OPNsenseBandwidth(
            rxRateBps: Double(rxDelta) / dt,
            txRateBps: Double(txDelta) / dt,
            linkSpeedMbps: new.linkSpeedMbps > 0 ? new.linkSpeedMbps : old.linkSpeedMbps
        )
    }

    // MARK: - Transport

    private static func requireSessionBaseURL(for host: String) throws -> URL {
        guard let baseURL = sessionBaseURL, sessionHost == host else {
            throw OPNsenseError.authFailed
        }
        return baseURL
    }

    private static func getJSON(
        baseURL: URL,
        path: String,
        apiKey: String,
        apiSecret: String
    ) async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(basicAuthHeader(apiKey: apiKey, apiSecret: apiSecret), forHTTPHeaderField: "Authorization")

        do {
            let session = makeSession()
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw OPNsenseError.requestFailed
            }

            switch httpResponse.statusCode {
            case 200:
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let responseBody = String(data: data, encoding: .utf8) ?? "(unable to decode)"
                    let truncated = responseBody.prefix(100)
                    print("OPNsense parse error. Response was: \(truncated)")
                    throw OPNsenseError.parseError
                }
                return json
            case 401, 403:
                throw OPNsenseError.authFailed
            default:
                throw OPNsenseError.httpStatus(httpResponse.statusCode)
            }
        } catch let error as OPNsenseError {
            throw error
        } catch {
            throw OPNsenseError.requestFailed
        }
    }

    private static func candidateBaseURLs(for host: String) throws -> [URL] {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OPNsenseError.invalidURL }

        if let components = URLComponents(string: trimmed), let scheme = components.scheme {
            let normalizedScheme = scheme.lowercased()
            guard normalizedScheme == "http" || normalizedScheme == "https",
                  let normalized = normalizeBaseURL(from: components) else {
                throw OPNsenseError.invalidURL
            }
            return [normalized]
        }

        guard let httpsURL = URL(string: "https://\(trimmed)"),
              let httpURL = URL(string: "http://\(trimmed)") else {
            throw OPNsenseError.invalidURL
        }

        return [httpsURL, httpURL]
    }

    private static func normalizeBaseURL(from components: URLComponents) -> URL? {
        guard let host = components.host else { return nil }
        var normalized = URLComponents()
        normalized.scheme = components.scheme?.lowercased()
        normalized.host = host
        normalized.port = components.port
        normalized.path = ""
        return normalized.url
    }

    private static func basicAuthHeader(apiKey: String, apiSecret: String) -> String {
        let raw = "\(apiKey):\(apiSecret)"
        let encoded = Data(raw.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }


    private static func uint64Value(_ any: Any?) -> UInt64 {
        switch any {
        case let value as UInt64:
            return value
        case let value as Int:
            return UInt64(max(value, 0))
        case let value as Int64:
            return UInt64(max(value, 0))
        case let value as NSNumber:
            return value.uint64Value
        case let value as String:
            return UInt64(value) ?? 0
        default:
            return 0
        }
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config, delegate: InsecureTLSDelegate.shared, delegateQueue: nil)
    }

    // MARK: - Keychain Helpers

    static func saveCredentials(host: String, apiKey: String, apiSecret: String) {
        let service = "com.local.netfluss.opnsense"
        let account = credentialAccount(for: host)
        let value = "\(apiKey)\n\(apiSecret)"

        guard let data = value.data(using: .utf8) else { return }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func loadCredentials(host: String) -> (apiKey: String, apiSecret: String)? {
        let service = "com.local.netfluss.opnsense"
        let account = credentialAccount(for: host)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        let parts = value.split(separator: "\n", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        return (apiKey: String(parts[0]), apiSecret: String(parts[1]))
    }

    static func deleteCredentials(host: String) {
        let service = "com.local.netfluss.opnsense"
        let account = credentialAccount(for: host)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func credentialAccount(for host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let normalizedHost = components.host else {
            return trimmed
        }
        if let port = components.port {
            return "\(normalizedHost):\(port)"
        }
        return normalizedHost
    }
}
