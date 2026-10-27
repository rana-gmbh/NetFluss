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

/// Calendar-aligned usage totals for the popover's "Data Usage" summary:
/// traffic accumulated since midnight (today) and since the 1st of the month.
struct StatisticsUsageSummary: Sendable, Equatable {
    var today: StatisticsTrafficAmounts = .init()
    var month: StatisticsTrafficAmounts = .init()

    static let empty = StatisticsUsageSummary()
}

struct StatisticsArchive: Codable, Sendable {
    static let currentAppTrafficSchemaVersion = 3

    var createdAt: Date
    var lastAdapterSampleAt: Date?
    var lastAppSampleAt: Date?
    var lastNodeSampleAt: Date?
    var appTrafficSchemaVersion: Int
    var adapterDisplayNames: [String: String]
    var adapterMinute: [String: [String: StatisticsTrafficAmounts]]
    var adapterHourly: [String: [String: StatisticsTrafficAmounts]]
    var adapterDaily: [String: [String: StatisticsTrafficAmounts]]
    var appMinute: [String: [String: StatisticsTrafficAmounts]]
    var appHourly: [String: [String: StatisticsTrafficAmounts]]
    var appDaily: [String: [String: StatisticsTrafficAmounts]]
    /// Per-proxy-node traffic from the Clash API (issue #61). Absent from
    /// archives written before 2.7, which is why every node field decodes
    /// through `decodeIfPresent`.
    var nodeMinute: [String: [String: StatisticsTrafficAmounts]]
    var nodeHourly: [String: [String: StatisticsTrafficAmounts]]
    var nodeDaily: [String: [String: StatisticsTrafficAmounts]]

    static let empty = StatisticsArchive(
        createdAt: Date(),
        lastAdapterSampleAt: nil,
        lastAppSampleAt: nil,
        lastNodeSampleAt: nil,
        appTrafficSchemaVersion: currentAppTrafficSchemaVersion,
        adapterDisplayNames: [:],
        adapterMinute: [:],
        adapterHourly: [:],
        adapterDaily: [:],
        appMinute: [:],
        appHourly: [:],
        appDaily: [:],
        nodeMinute: [:],
        nodeHourly: [:],
        nodeDaily: [:]
    )

    private enum CodingKeys: String, CodingKey {
        case createdAt
        case lastAdapterSampleAt
        case lastAppSampleAt
        case lastNodeSampleAt
        case appTrafficSchemaVersion
        case adapterDisplayNames
        case adapterMinute
        case adapterHourly
        case adapterDaily
        case appMinute
        case appHourly
        case appDaily
        case nodeMinute
        case nodeHourly
        case nodeDaily
    }

    init(
        createdAt: Date,
        lastAdapterSampleAt: Date?,
        lastAppSampleAt: Date?,
        lastNodeSampleAt: Date? = nil,
        appTrafficSchemaVersion: Int = Self.currentAppTrafficSchemaVersion,
        adapterDisplayNames: [String: String],
        adapterMinute: [String: [String: StatisticsTrafficAmounts]],
        adapterHourly: [String: [String: StatisticsTrafficAmounts]],
        adapterDaily: [String: [String: StatisticsTrafficAmounts]],
        appMinute: [String: [String: StatisticsTrafficAmounts]],
        appHourly: [String: [String: StatisticsTrafficAmounts]],
        appDaily: [String: [String: StatisticsTrafficAmounts]],
        nodeMinute: [String: [String: StatisticsTrafficAmounts]] = [:],
        nodeHourly: [String: [String: StatisticsTrafficAmounts]] = [:],
        nodeDaily: [String: [String: StatisticsTrafficAmounts]] = [:]
    ) {
        self.createdAt = createdAt
        self.lastAdapterSampleAt = lastAdapterSampleAt
        self.lastAppSampleAt = lastAppSampleAt
        self.lastNodeSampleAt = lastNodeSampleAt
        self.appTrafficSchemaVersion = appTrafficSchemaVersion
        self.adapterDisplayNames = adapterDisplayNames
        self.adapterMinute = adapterMinute
        self.adapterHourly = adapterHourly
        self.adapterDaily = adapterDaily
        self.appMinute = appMinute
        self.appHourly = appHourly
        self.appDaily = appDaily
        self.nodeMinute = nodeMinute
        self.nodeHourly = nodeHourly
        self.nodeDaily = nodeDaily
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastAdapterSampleAt = try container.decodeIfPresent(Date.self, forKey: .lastAdapterSampleAt)
        lastAppSampleAt = try container.decodeIfPresent(Date.self, forKey: .lastAppSampleAt)
        lastNodeSampleAt = try container.decodeIfPresent(Date.self, forKey: .lastNodeSampleAt)
        appTrafficSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .appTrafficSchemaVersion) ?? 0
        adapterDisplayNames = try container.decodeIfPresent([String: String].self, forKey: .adapterDisplayNames) ?? [:]
        adapterMinute = try container.decodeIfPresent([String: [String: StatisticsTrafficAmounts]].self, forKey: .adapterMinute) ?? [:]
        adapterHourly = try container.decodeIfPresent([String: [String: StatisticsTrafficAmounts]].self, forKey: .adapterHourly) ?? [:]
        adapterDaily = try container.decodeIfPresent([String: [String: StatisticsTrafficAmounts]].self, forKey: .adapterDaily) ?? [:]
        appMinute = try container.decodeIfPresent([String: [String: StatisticsTrafficAmounts]].self, forKey: .appMinute) ?? [:]
        appHourly = try container.decodeIfPresent([String: [String: StatisticsTrafficAmounts]].self, forKey: .appHourly) ?? [:]
        appDaily = try container.decodeIfPresent([String: [String: StatisticsTrafficAmounts]].self, forKey: .appDaily) ?? [:]
        nodeMinute = try container.decodeIfPresent([String: [String: StatisticsTrafficAmounts]].self, forKey: .nodeMinute) ?? [:]
        nodeHourly = try container.decodeIfPresent([String: [String: StatisticsTrafficAmounts]].self, forKey: .nodeHourly) ?? [:]
        nodeDaily = try container.decodeIfPresent([String: [String: StatisticsTrafficAmounts]].self, forKey: .nodeDaily) ?? [:]
    }
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

/// One proxy node's traffic in a single sampling interval (issue #61).
struct StatisticsNodeDelta: Sendable, Equatable {
    let name: String
    let downloadBytes: UInt64
    let uploadBytes: UInt64
}

enum StatisticsRange: String, CaseIterable, Identifiable, Sendable {
    case lastHour = "1H"
    case last24Hours = "24H"
    case last7Days = "7D"
    case last30Days = "30D"
    case lastYear = "1Y"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastHour: return "Last Hour"
        case .last24Hours: return "Last 24 Hours"
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        case .lastYear: return "Last Year"
        }
    }

    var bucketTitle: String {
        switch self {
        case .lastHour: return "Minute Traffic"
        case .last24Hours: return "Hourly Traffic"
        case .last7Days, .last30Days: return "Daily Traffic"
        case .lastYear: return "Monthly Traffic"
        }
    }
}

enum StatisticsTimelineGranularity: Sendable {
    case minute
    case hour
    case day
    case month
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

/// A proxy node's totals for the selected range. Shaped like
/// `StatisticsAdapterRow` because it renders the same way: a quota reader wants
/// sent and received side by side, not two separate top-ten lists.
struct StatisticsNodeRow: Identifiable, Sendable {
    let id: String
    let name: String
    let downloadBytes: UInt64
    let uploadBytes: UInt64

    var totalBytes: UInt64 { downloadBytes + uploadBytes }
}

struct StatisticsReport: Sendable {
    let range: StatisticsRange
    let displayTitle: String
    let displayBucketTitle: String
    let timelineGranularity: StatisticsTimelineGranularity
    let timelineStart: Date
    let timelineEnd: Date
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
    let nodes: [StatisticsNodeRow]

    var hasAdapterData: Bool {
        totalDownloadBytes > 0 || totalUploadBytes > 0 || !adapters.isEmpty || !timeline.isEmpty
    }

    var hasAppData: Bool {
        !topDownloadApps.isEmpty || !topUploadApps.isEmpty
    }

    var hasNodeData: Bool {
        !nodes.isEmpty
    }
}
