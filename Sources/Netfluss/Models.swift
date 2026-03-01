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

enum AdapterType: String {
    case wifi
    case ethernet
    case other
}

struct AdapterStatus: Identifiable {
    let id: String          // BSD name (e.g. "en0")
    let displayName: String
    let type: AdapterType
    let isUp: Bool
    let linkSpeedBps: UInt64?
    let wifiMode: String?
    let wifiTxRateMbps: Double?
    let wifiSSID: String?
    let rxBytes: UInt64
    let txBytes: UInt64
    let rxRateBps: Double
    let txRateBps: Double
}

struct RateTotals {
    let rxRateBps: Double
    let txRateBps: Double
}

struct AppTraffic: Identifiable {
    let id: String
    let name: String
    let rxRateBps: Double
    let txRateBps: Double
}

struct InterfaceSample {
    let name: String
    let flags: UInt32
    let rxBytes: UInt64
    let txBytes: UInt64
    let baudrate: UInt64
}
