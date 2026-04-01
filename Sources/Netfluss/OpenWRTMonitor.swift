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
    case requestFailed
    case parseError
    case noWANDevice
}

enum OpenWRTMonitor {

    // MARK: - Session Management

    private static var sessionToken: String?
    private static var sessionHost: String?

    /// Authenticate via ubus JSON-RPC and store the session token.
    static func login(host: String, username: String, password: String) async throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenWRTError.invalidURL }

        let urlString = "http://\(trimmed)/ubus"
        guard let url = URL(string: urlString) else { throw OpenWRTError.invalidURL }

        let rpcBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "call",
            "params": [
                "00000000000000000000000000000000",
                "session",
                "login",
                ["username": username, "password": password]
            ]
        ]

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: rpcBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OpenWRTError.authFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [Any],
              result.count >= 2,
              let resultCode = result[0] as? Int, resultCode == 0,
              let sessionData = result[1] as? [String: Any],
              let token = sessionData["ubus_rpc_session"] as? String else {
            throw OpenWRTError.authFailed
        }

        sessionToken = token
        sessionHost = trimmed
    }

    /// Discover the WAN device name by querying network.interface.wan.
    static func discoverWANDevice(host: String) async throws -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = sessionToken else { throw OpenWRTError.authFailed }

        let urlString = "http://\(trimmed)/ubus"
        guard let url = URL(string: urlString) else { throw OpenWRTError.invalidURL }

        let rpcBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "call",
            "params": [token, "network.interface.wan", "status", [:] as [String: Any]]
        ]

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: rpcBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OpenWRTError.requestFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [Any],
              result.count >= 2,
              let resultCode = result[0] as? Int, resultCode == 0,
              let statusData = result[1] as? [String: Any] else {
            throw OpenWRTError.parseError
        }

        // Use l3_device first (handles PPPoE), then device
        if let device = statusData["l3_device"] as? String, !device.isEmpty { return device }
        if let device = statusData["device"] as? String, !device.isEmpty { return device }

        throw OpenWRTError.noWANDevice
    }

    /// Fetch raw byte counters for a given network device.
    static func fetchDeviceStats(host: String, device: String) async throws -> OpenWRTSample {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = sessionToken else { throw OpenWRTError.authFailed }

        let urlString = "http://\(trimmed)/ubus"
        guard let url = URL(string: urlString) else { throw OpenWRTError.invalidURL }

        let rpcBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "call",
            "params": [token, "network.device", "status", ["name": device]]
        ]

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: rpcBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OpenWRTError.requestFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [Any],
              result.count >= 2,
              let resultCode = result[0] as? Int, resultCode == 0,
              let deviceData = result[1] as? [String: Any] else {
            // Check if session expired (result code 6 = permission denied)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [Any],
               let code = result.first as? Int, code == 6 {
                sessionToken = nil
                throw OpenWRTError.authFailed
            }
            throw OpenWRTError.parseError
        }

        let stats = deviceData["statistics"] as? [String: Any] ?? [:]
        let rxBytes = (stats["rx_bytes"] as? UInt64) ?? (stats["rx_bytes"] as? Int).map(UInt64.init) ?? 0
        let txBytes = (stats["tx_bytes"] as? UInt64) ?? (stats["tx_bytes"] as? Int).map(UInt64.init) ?? 0

        let speedStr = deviceData["speed"] as? String ?? "0"
        let linkSpeed = UInt64(speedStr) ?? 0

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
        if sessionToken == nil || sessionHost != trimmed {
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

    // MARK: - Keychain Helpers

    static func saveCredentials(host: String, username: String, password: String) {
        let service = "com.local.netfluss.openwrt"
        let account = host

        let value = "\(username)\n\(password)"
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

    static func loadCredentials(host: String) -> (username: String, password: String)? {
        let service = "com.local.netfluss.openwrt"
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
        let service = "com.local.netfluss.openwrt"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host
        ]
        SecItemDelete(query as CFDictionary)
    }
}
