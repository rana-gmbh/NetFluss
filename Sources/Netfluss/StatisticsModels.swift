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

struct StatisticsTrafficAmounts: Codable, Equatable, Sendable {
    var downloadBytes: UInt64 = 0
    var uploadBytes: UInt64 = 0

    var totalBytes: UInt64 { downloadBytes + uploadBytes }

    mutating func add(downloadBytes: UInt64, uploadBytes: UInt64) {
        self.downloadBytes += downloadBytes
        self.uploadBytes += uploadBytes
    }

    mutating func merge(_ other: StatisticsTrafficAmounts) {
        add(downloadBytes: other.downloadBytes, uploadBytes: other.uploadBytes)
    }
}

struct StatisticsArchive: Codable, Sendable {
    var createdAt: Date
    var lastAdapterSampleAt: Date?
    var lastAppSampleAt: Date?
    var adapterDisplayNames: [String: String]
    var adapterHourly: [String: [String: StatisticsTrafficAmounts]]
    var adapterDaily: [String: [String: StatisticsTrafficAmounts]]
    var appHourly: [String: [String: StatisticsTrafficAmounts]]
    var appDaily: [String: [String: StatisticsTrafficAmounts]]

    static let empty = StatisticsArchive(
        createdAt: Date(),
        lastAdapterSampleAt: nil,
        lastAppSampleAt: nil,
        adapterDisplayNames: [:],
        adapterHourly: [:],
        adapterDaily: [:],
        appHourly: [:],
        appDaily: [:]
    )
}

struct StatisticsAdapterDelta: Sendable {
    let id: String
    let displayName: String
    let downloadBytes: UInt64
    let uploadBytes: UInt64
}

struct StatisticsAppDelta: Sendable {
    let name: String
    let downloadBytes: UInt64
    let uploadBytes: UInt64
}

enum StatisticsRange: String, CaseIterable, Identifiable, Sendable {
    case last24Hours = "24H"
    case last7Days = "7D"
    case last30Days = "30D"
    case lastYear = "1Y"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .last24Hours: return "Last 24 Hours"
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        case .lastYear: return "Last Year"
        }
    }

    var bucketTitle: String {
        switch self {
        case .last24Hours: return "Hourly Traffic"
        case .last7Days, .last30Days: return "Daily Traffic"
        case .lastYear: return "Monthly Traffic"
        }
    }
}

struct StatisticsTimelinePoint: Identifiable, Sendable {
    let id: String
    let date: Date
    let downloadBytes: UInt64
    let uploadBytes: UInt64
}

struct StatisticsAdapterRow: Identifiable, Sendable {
    let id: String
    let name: String
    let downloadBytes: UInt64
    let uploadBytes: UInt64

    var totalBytes: UInt64 { downloadBytes + uploadBytes }
}

struct StatisticsAppRow: Identifiable, Sendable {
    let id: String
    let name: String
    let bytes: UInt64
}

struct StatisticsReport: Sendable {
    let range: StatisticsRange
    let createdAt: Date
    let coverageStart: Date?
    let lastAdapterSampleAt: Date?
    let lastAppSampleAt: Date?
    let totalDownloadBytes: UInt64
    let totalUploadBytes: UInt64
    let timeline: [StatisticsTimelinePoint]
    let adapters: [StatisticsAdapterRow]
    let topDownloadApps: [StatisticsAppRow]
    let topUploadApps: [StatisticsAppRow]

    var hasAdapterData: Bool {
        totalDownloadBytes > 0 || totalUploadBytes > 0 || !adapters.isEmpty || !timeline.isEmpty
    }

    var hasAppData: Bool {
        !topDownloadApps.isEmpty || !topUploadApps.isEmpty
    }
}
