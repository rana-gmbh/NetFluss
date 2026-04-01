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

enum AdapterType: String, Equatable, Sendable {
    case wifi
    case ethernet
    case other
}

struct AdapterStatus: Identifiable, Equatable, Sendable {
    let id: String          // BSD name (e.g. "en0")
    let displayName: String
    let type: AdapterType
    let isUp: Bool
    let linkSpeedBps: UInt64?
    let wifiMode: String?
    let wifiTxRateMbps: Double?
    let wifiSSID: String?
    let wifiDetail: WifiDetail?
    let rxBytes: UInt64
    let txBytes: UInt64
    let rxRateBps: Double
    let txRateBps: Double
}

struct RateTotals: Equatable, Sendable {
    let rxRateBps: Double
    let txRateBps: Double
}

struct AppTraffic: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let rxRateBps: Double
    let txRateBps: Double
}

struct WifiDetail: Equatable, Sendable {
    let phyMode: String?
    let security: String?
    let channelNumber: Int?
    let channelWidth: String?
    let rssi: Int?
    let noise: Int?
    let bssid: String?
}

struct InterfaceSample: Equatable, Sendable {
    let name: String
    let flags: UInt32
    let rxBytes: UInt64
    let txBytes: UInt64
    let baudrate: UInt64
}

struct DNSPreset: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let servers: [String]  // empty = system default (DHCP)
    let isBuiltIn: Bool

    static let builtIn: [DNSPreset] = [
        DNSPreset(id: "system",    name: "System Default", servers: [],                              isBuiltIn: true),
        DNSPreset(id: "cloudflare",name: "Cloudflare",     servers: ["1.1.1.1", "1.0.0.1"],          isBuiltIn: true),
        DNSPreset(id: "google",    name: "Google",         servers: ["8.8.8.8", "8.8.4.4"],          isBuiltIn: true),
        DNSPreset(id: "quad9",     name: "Quad9",          servers: ["9.9.9.9", "149.112.112.112"],  isBuiltIn: true),
        DNSPreset(id: "opendns",   name: "OpenDNS",        servers: ["208.67.222.222", "208.67.220.220"], isBuiltIn: true),
    ]
}
