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

struct OpenWRTBandwidth: Equatable, Sendable {
    let rxRateBps: Double
    let txRateBps: Double
    let linkSpeedMbps: UInt64
}

struct OpenWRTSample: Equatable, Sendable {
    let rxBytes: UInt64
    let txBytes: UInt64
    let linkSpeedMbps: UInt64
    let timestamp: Date
}

enum OpenWRTError: Error {
    case invalidURL
    case authFailed
    case ubusUnavailable
    case httpStatus(Int)
    case rpcFailure(Int, String)
    case requestFailed
    case parseError
    case noWANDevice
}

enum OpenWRTMonitor {

    // MARK: - Session Management

    private static var sessionToken: String?
    private static var sessionHost: String?
    private static var sessionURL: URL?

    private static let anonymousSessionID = "00000000000000000000000000000000"

    // MARK: - Public API

    /// Authenticate via ubus JSON-RPC and store the session token.
    static func login(host: String, username: String, password: String) async throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenWRTError.invalidURL }
        sessionToken = nil
        sessionHost = nil
        sessionURL = nil

        var lastError: Error = OpenWRTError.requestFailed
        for url in try candidateURLs(for: trimmed) {
            do {
                let rpcData = try await call(
                    url: url,
                    rpcID: 1,
                    sessionID: anonymousSessionID,
                    object: "session",
                    method: "login",
                    arguments: ["username": username, "password": password]
                )
                guard let token = rpcData["ubus_rpc_session"] as? String, !token.isEmpty else {
                    throw OpenWRTError.authFailed
                }

                sessionToken = token
                sessionHost = trimmed
                sessionURL = url
                return
            } catch OpenWRTError.authFailed {
                throw OpenWRTError.authFailed
            } catch OpenWRTError.rpcFailure(let code, _) where code == ubusStatusPermissionDenied {
                throw OpenWRTError.authFailed
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    /// Discover the WAN device name by querying network.interface.wan, then falling back to interface dump.
    static func discoverWANDevice(host: String) async throws -> String {
        guard let token = sessionToken else { throw OpenWRTError.authFailed }
        let status: [String: Any]

        do {
            status = try await call(
                host: host,
                rpcID: 2,
                sessionID: token,
                object: "network.interface.wan",
                method: "status",
                arguments: [:]
            )
            if let device = deviceName(from: status) {
                return device
            }
        } catch OpenWRTError.authFailed {
            throw OpenWRTError.authFailed
        } catch OpenWRTError.rpcFailure(let code, _) where code == ubusStatusPermissionDenied {
            sessionToken = nil
            throw OpenWRTError.authFailed
        } catch {
            // Fall back to a full interface dump when the direct wan object is unavailable.
        }

        let dump = try await call(
            host: host,
            rpcID: 3,
            sessionID: token,
            object: "network.interface",
            method: "dump",
            arguments: [:]
        )
        guard let interfaces = dump["interface"] as? [[String: Any]],
              let device = pickWANDevice(from: interfaces) else {
            throw OpenWRTError.noWANDevice
        }
        return device
    }

    /// Fetch raw byte counters for a given network device.
    static func fetchDeviceStats(host: String, device: String) async throws -> OpenWRTSample {
        guard let token = sessionToken else { throw OpenWRTError.authFailed }
        let deviceData = try await call(
            host: host,
            rpcID: 4,
            sessionID: token,
            object: "network.device",
            method: "status",
            arguments: ["name": device]
        )

        let stats = deviceData["statistics"] as? [String: Any] ?? [:]
        let rxBytes = uint64Value(stats["rx_bytes"])
        let txBytes = uint64Value(stats["tx_bytes"])

        let linkSpeed: UInt64
        let speed = uint64Value(deviceData["speed"])
        if speed > 0 {
            linkSpeed = speed
        } else if let speedStr = deviceData["speed"] as? String {
            linkSpeed = UInt64(speedStr) ?? 0
        } else {
            linkSpeed = 0
        }

        return OpenWRTSample(
            rxBytes: rxBytes,
            txBytes: txBytes,
            linkSpeedMbps: linkSpeed,
            timestamp: Date()
        )
    }

    /// High-level: fetch bandwidth by sampling counters. Requires two calls over time.
    /// The caller is responsible for storing the previous sample and computing rates.
    static func fetchSample(host: String, username: String, password: String) async throws -> OpenWRTSample {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenWRTError.invalidURL }

        // Login if needed or host changed
        if sessionToken == nil || sessionHost != trimmed || sessionURL == nil {
            try await login(host: trimmed, username: username, password: password)
        }

        // Discover WAN device
        let device: String
        do {
            device = try await discoverWANDevice(host: trimmed)
        } catch {
            // Maybe session expired — re-login once
            if sessionToken == nil {
                try await login(host: trimmed, username: username, password: password)
                return try await fetchSampleInner(host: trimmed, username: username, password: password)
            }
            throw error
        }

        do {
            return try await fetchDeviceStats(host: trimmed, device: device)
        } catch OpenWRTError.authFailed {
            // Session expired — re-login and retry
            try await login(host: trimmed, username: username, password: password)
            return try await fetchSampleInner(host: trimmed, username: username, password: password)
        }
    }

    private static func fetchSampleInner(host: String, username: String, password: String) async throws -> OpenWRTSample {
        let device = try await discoverWANDevice(host: host)
        return try await fetchDeviceStats(host: host, device: device)
    }

    // MARK: - Transport

    private static let ubusStatusPermissionDenied = 6

    private static func call(
        host: String,
        rpcID: Int,
        sessionID: String,
        object: String,
        method: String,
        arguments: [String: Any]
    ) async throws -> [String: Any] {
        guard let url = sessionURL, sessionHost == host else {
            throw OpenWRTError.authFailed
        }
        return try await call(
            url: url,
            rpcID: rpcID,
            sessionID: sessionID,
            object: object,
            method: method,
            arguments: arguments
        )
    }

    private static func call(
        url: URL,
        rpcID: Int,
        sessionID: String,
        object: String,
        method: String,
        arguments: [String: Any]
    ) async throws -> [String: Any] {
        let rpcBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": rpcID,
            "method": "call",
            "params": [sessionID, object, method, arguments]
        ]

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: rpcBody)

        do {
            let session = makeSession()
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OpenWRTError.requestFailed
            }

            switch httpResponse.statusCode {
            case 200:
                return try parseRPCPayload(data)
            case 401, 403:
                throw OpenWRTError.authFailed
            case 404:
                throw OpenWRTError.ubusUnavailable
            default:
                throw OpenWRTError.httpStatus(httpResponse.statusCode)
            }
        } catch let error as OpenWRTError {
            throw error
        } catch {
            throw OpenWRTError.requestFailed
        }
    }

    private static func candidateURLs(for host: String) throws -> [URL] {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenWRTError.invalidURL }

        if let components = URLComponents(string: trimmed), let scheme = components.scheme {
            let normalizedScheme = scheme.lowercased()
            guard let normalized = normalizeBaseURL(from: components),
                  normalizedScheme == "http" || normalizedScheme == "https" else {
                throw OpenWRTError.invalidURL
            }
            return [normalized]
        }

        guard let httpsURL = URL(string: "https://\(trimmed)"),
              let httpURL = URL(string: "http://\(trimmed)") else {
            throw OpenWRTError.invalidURL
        }
        return [httpsURL.appending(path: "ubus"), httpURL.appending(path: "ubus")]
    }

    private static func normalizeBaseURL(from components: URLComponents) -> URL? {
        guard let host = components.host else { return nil }
        var normalized = URLComponents()
        normalized.scheme = components.scheme?.lowercased()
        normalized.host = host
        normalized.port = components.port
        normalized.path = "/ubus"
        return normalized.url
    }

    private static func parseRPCPayload(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenWRTError.ubusUnavailable
        }

        if let error = json["error"] as? [String: Any] {
            let code = intValue(error["code"])
            let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OpenWRTError.rpcFailure(code, message ?? "JSON-RPC error")
        }

        guard let result = json["result"] as? [Any], !result.isEmpty else {
            throw OpenWRTError.ubusUnavailable
        }

        let statusCode = intValue(result[0])
        guard statusCode == 0 else {
            throw mapRPCFailure(code: statusCode)
        }

        if result.count < 2 {
            return [:]
        }
        guard let payload = result[1] as? [String: Any] else {
            throw OpenWRTError.parseError
        }
        return payload
    }

    private static func mapRPCFailure(code: Int) -> OpenWRTError {
        switch code {
        case ubusStatusPermissionDenied:
            sessionToken = nil
            return .authFailed
        default:
            return .rpcFailure(code, rpcStatusMessage(for: code))
        }
    }

    private static func rpcStatusMessage(for code: Int) -> String {
        switch code {
        case 0:
            return "Success"
        case 1:
            return "Invalid command"
        case 2:
            return "Invalid argument"
        case 3:
            return "Method not found"
        case 4:
            return "Not found"
        case 5:
            return "No response"
        case 6:
            return "Permission denied"
        case 7:
            return "Request timed out"
        case 8:
            return "Operation not supported"
        case 9:
            return "Unknown error"
        case 10:
            return "Connection failed"
        case 11:
            return "Out of memory"
        case 12:
            return "Parsing message data failed"
        case 13:
            return "System error"
        default:
            return "Unknown error: \(code)"
        }
    }

    private static func deviceName(from interface: [String: Any]) -> String? {
        if let device = interface["l3_device"] as? String, !device.isEmpty {
            return device
        }
        if let device = interface["device"] as? String, !device.isEmpty {
            return device
        }
        return nil
    }

    private static func pickWANDevice(from interfaces: [[String: Any]]) -> String? {
        let activeInterfaces = interfaces.filter { boolValue($0["up"]) || boolValue($0["pending"]) }

        if let routed = activeInterfaces
            .compactMap({ interface -> (device: String, metric: Int)? in
                guard let device = deviceName(from: interface),
                      hasDefaultRoute(interface: interface) else {
                    return nil
                }
                return (device, defaultRouteMetric(interface: interface))
            })
            .sorted(by: { $0.metric < $1.metric })
            .first {
            return routed.device
        }

        if let namedWAN = activeInterfaces.first(where: { interface in
            let name = (interface["interface"] as? String)?.lowercased() ?? ""
            return name == "wan" || name.hasPrefix("wan")
        }).flatMap(deviceName(from:)) {
            return namedWAN
        }

        if let fallback = activeInterfaces.first(where: { deviceName(from: $0) != nil }).flatMap(deviceName(from:)) {
            return fallback
        }

        return interfaces.first(where: { deviceName(from: $0) != nil }).flatMap(deviceName(from:))
    }

    private static func hasDefaultRoute(interface: [String: Any]) -> Bool {
        guard let routes = interface["route"] as? [[String: Any]] else { return false }
        return routes.contains { route in
            intValue(route["mask"]) == 0 &&
                ["0.0.0.0", "::", ""].contains((route["target"] as? String) ?? "")
        }
    }

    private static func defaultRouteMetric(interface: [String: Any]) -> Int {
        guard let routes = interface["route"] as? [[String: Any]] else { return Int.max }
        return routes
            .filter {
                intValue($0["mask"]) == 0 &&
                    ["0.0.0.0", "::", ""].contains(($0["target"] as? String) ?? "")
            }
            .map { intValue($0["metric"], default: Int.max) }
            .min() ?? Int.max
    }

    private static func intValue(_ any: Any?, default fallback: Int = 0) -> Int {
        switch any {
        case let value as Int:
            return value
        case let value as Int64:
            return Int(value)
        case let value as UInt64:
            return Int(value)
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value) ?? fallback
        default:
            return fallback
        }
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

    private static func boolValue(_ any: Any?) -> Bool {
        switch any {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            return ["1", "true", "yes"].contains(value.lowercased())
        default:
            return false
        }
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config, delegate: InsecureTLSDelegate.shared, delegateQueue: nil)
    }

    // MARK: - Keychain Helpers

    static func saveCredentials(host: String, username: String, password: String) {
        let service = "com.local.netfluss.openwrt"
        let account = credentialAccount(for: host)

        let value = "\(username)\n\(password)"
        guard let data = value.data(using: .utf8) else { return }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        if account != host {
            let legacyDeleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: host
            ]
            SecItemDelete(legacyDeleteQuery as CFDictionary)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func loadCredentials(host: String) -> (username: String, password: String)? {
        let service = "com.local.netfluss.openwrt"
        let accounts = [credentialAccount(for: host), host]
        for account in Array(Set(accounts)) {
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
                  let value = String(data: data, encoding: .utf8) else { continue }

            let parts = value.split(separator: "\n", maxSplits: 1)
            guard parts.count == 2 else { continue }
            return (username: String(parts[0]), password: String(parts[1]))
        }
        return nil
    }

    static func deleteCredentials(host: String) {
        let service = "com.local.netfluss.openwrt"
        for account in Array(Set([credentialAccount(for: host), host])) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    private static func credentialAccount(for host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let normalizedHost = components.host else {
            return trimmed
        }
        if let port = components.port {
            return "\(normalizedHost):\(port)"
        }
        return normalizedHost
    }
}
