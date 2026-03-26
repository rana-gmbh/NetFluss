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

struct RateFormatter {
    static func formatRate(_ bytesPerSecond: Double, useBits: Bool) -> String {
        let value = max(0, bytesPerSecond)
        if useBits {
            return format(value * 8.0, units: ["b/s", "Kb/s", "Mb/s", "Gb/s", "Tb/s"])
        }
        return format(value, units: ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"])
    }

    static func formatLinkSpeed(_ bps: UInt64?, useBits: Bool) -> String {
        guard let bps else { return "—" }
        if useBits {
            return format(Double(bps), units: ["b/s", "Kb/s", "Mb/s", "Gb/s", "Tb/s"])
        }
        return format(Double(bps) / 8.0, units: ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"])
    }

    static func formatMbps(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1000 {
            return String(format: "%.1f Gb/s", value / 1000.0)
        }
        return String(format: "%.0f Mb/s", value)
    }

    /// Format a rate with a pinned unit scale and fixed decimal places.
    /// `pinnedUnit`: "auto", "K", "M", "G"  — the scale to pin to.
    /// `decimals`: number of decimal places (0–3).
    static func formatRate(_ bytesPerSecond: Double, useBits: Bool, pinnedUnit: String, decimals: Int) -> String {
        let value = max(0, bytesPerSecond)
        let base = useBits ? value * 8.0 : value
        let units = useBits ? ["b/s", "Kb/s", "Mb/s", "Gb/s", "Tb/s"] : ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]

        if pinnedUnit == "auto" {
            return format(base, units: units, decimals: decimals)
        }

        let scaleIndex: Int
        switch pinnedUnit {
        case "K": scaleIndex = 1
        case "M": scaleIndex = 2
        case "G": scaleIndex = 3
        default:  scaleIndex = 0
        }

        let divisor = pow(1000.0, Double(scaleIndex))
        let adjusted = base / divisor
        let unit = scaleIndex < units.count ? units[scaleIndex] : units.last!
        let fmt = "%.\(decimals)f"
        return String(format: fmt + " %@", adjusted, unit)
    }

    private static func format(_ value: Double, units: [String], decimals: Int) -> String {
        var adjusted = value
        var unitIndex = 0
        while adjusted >= 1000.0 && unitIndex < units.count - 1 {
            adjusted /= 1000.0
            unitIndex += 1
        }
        let fmt = "%.\(decimals)f"
        return String(format: fmt + " %@", adjusted, units[unitIndex])
    }

    private static func format(_ value: Double, units: [String]) -> String {
        var adjusted = value
        var unitIndex = 0
        while adjusted >= 1000.0 && unitIndex < units.count - 1 {
            adjusted /= 1000.0
            unitIndex += 1
        }
        let formatString: String
        switch adjusted {
        case 0..<10:
            formatString = "%.2f"
        case 10..<100:
            formatString = "%.1f"
        default:
            formatString = "%.0f"
        }
        return String(format: formatString + " %@", adjusted, units[unitIndex])
    }
}
