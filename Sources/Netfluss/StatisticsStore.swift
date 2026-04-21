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

actor StatisticsStore {
    private enum Constants {
        static let flushInterval: TimeInterval = 300
        static let minuteRetentionMinutes = 180
        static let hourlyRetentionHours = 72
        static let dailyRetentionDays = 400
    }

    private let url: URL?
    private var archive: StatisticsArchive
    private var hasPendingChanges = false
    private var lastFlushAt: Date?
    private let calendar = Calendar.autoupdatingCurrent

    init(url: URL) {
        self.url = url
        let loaded = Self.loadArchive(from: url)
        self.archive = loaded.archive
        self.hasPendingChanges = loaded.didMigrate
    }

    init(archive: StatisticsArchive) {
        self.url = nil
        self.archive = archive
    }

    func recordAdapterDeltas(_ deltas: [StatisticsAdapterDelta], at date: Date) async {
        guard !deltas.isEmpty else { return }
        let minuteKey = Self.minuteKey(for: date, calendar: calendar)
        let hourKey = Self.hourKey(for: date, calendar: calendar)
        let dayKey = Self.dayKey(for: date, calendar: calendar)

        for delta in deltas where delta.downloadBytes > 0 || delta.uploadBytes > 0 {
            archive.adapterDisplayNames[delta.id] = delta.displayName
            accumulate(
                into: &archive.adapterMinute,
                bucketKey: minuteKey,
                itemKey: delta.id,
                downloadBytes: delta.downloadBytes,
                uploadBytes: delta.uploadBytes
            )
            accumulate(
                into: &archive.adapterHourly,
                bucketKey: hourKey,
                itemKey: delta.id,
                downloadBytes: delta.downloadBytes,
                uploadBytes: delta.uploadBytes
            )
            accumulate(
                into: &archive.adapterDaily,
                bucketKey: dayKey,
                itemKey: delta.id,
                downloadBytes: delta.downloadBytes,
                uploadBytes: delta.uploadBytes
            )
        }

        archive.lastAdapterSampleAt = date
        hasPendingChanges = true
        prune(now: date)
        saveIfNeeded(now: date)
    }

    func recordAppDeltas(_ deltas: [StatisticsAppDelta], at date: Date) async {
        guard !deltas.isEmpty else { return }
        let minuteKey = Self.minuteKey(for: date, calendar: calendar)
        let hourKey = Self.hourKey(for: date, calendar: calendar)
        let dayKey = Self.dayKey(for: date, calendar: calendar)

        for delta in deltas where delta.downloadBytes > 0 || delta.uploadBytes > 0 {
            accumulate(
                into: &archive.appMinute,
                bucketKey: minuteKey,
                itemKey: delta.name,
                downloadBytes: delta.downloadBytes,
                uploadBytes: delta.uploadBytes
            )
            accumulate(
                into: &archive.appHourly,
                bucketKey: hourKey,
                itemKey: delta.name,
                downloadBytes: delta.downloadBytes,
                uploadBytes: delta.uploadBytes
            )
            accumulate(
                into: &archive.appDaily,
                bucketKey: dayKey,
                itemKey: delta.name,
                downloadBytes: delta.downloadBytes,
                uploadBytes: delta.uploadBytes
            )
        }

        archive.lastAppSampleAt = date
        hasPendingChanges = true
        prune(now: date)
        saveIfNeeded(now: date)
    }

    func flush(force: Bool = false) {
        guard hasPendingChanges else { return }
        let now = Date()
        if force || lastFlushAt == nil || now.timeIntervalSince(lastFlushAt ?? now) >= Constants.flushInterval {
            save()
        }
    }

    func report(
        for range: StatisticsRange,
        now: Date,
        customAdapterNames: [String: String],
        hiddenApps: Set<String>
    ) -> StatisticsReport {
        let adapterSource: [String: [String: StatisticsTrafficAmounts]]
        let appSource: [String: [String: StatisticsTrafficAmounts]]
        let relevantKeys: [String]
        let timelineGranularity: StatisticsTimelineGranularity
        let timelineStart: Date

        switch range {
        case .lastHour:
            adapterSource = archive.adapterMinute
            appSource = archive.appMinute
            relevantKeys = Self.minuteKeys(endingAt: now, count: 60, calendar: calendar)
            timelineGranularity = .minute
            timelineStart = calendar.date(byAdding: .minute, value: -59, to: now) ?? now
        case .last24Hours:
            adapterSource = archive.adapterHourly
            appSource = archive.appHourly
            relevantKeys = Self.hourKeys(endingAt: now, count: 24, calendar: calendar)
            timelineGranularity = .hour
            timelineStart = calendar.date(byAdding: .hour, value: -23, to: now) ?? now
        case .last7Days:
            adapterSource = archive.adapterDaily
            appSource = archive.appDaily
            relevantKeys = Self.dayKeys(endingAt: now, count: 7, calendar: calendar)
            timelineGranularity = .day
            timelineStart = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        case .last30Days:
            adapterSource = archive.adapterDaily
            appSource = archive.appDaily
            relevantKeys = Self.dayKeys(endingAt: now, count: 30, calendar: calendar)
            timelineGranularity = .day
            timelineStart = calendar.date(byAdding: .day, value: -29, to: now) ?? now
        case .lastYear:
            adapterSource = archive.adapterDaily
            appSource = archive.appDaily
            relevantKeys = Self.dayKeys(endingAt: now, count: 365, calendar: calendar)
            timelineGranularity = .month
            timelineStart = calendar.date(byAdding: .day, value: -364, to: now) ?? now
        }

        return makeReport(
            range: range,
            displayTitle: range.title,
            displayBucketTitle: range.bucketTitle,
            timelineGranularity: timelineGranularity,
            timelineStart: timelineStart,
            timelineEnd: now,
            adapterSource: adapterSource,
            appSource: appSource,
            relevantKeys: relevantKeys,
            customAdapterNames: customAdapterNames,
            hiddenApps: hiddenApps
        )
    }

    func report(
        customStart: Date,
        customEnd: Date,
        now: Date,
        customAdapterNames: [String: String],
        hiddenApps: Set<String>
    ) -> StatisticsReport {
        let boundedEnd = min(max(customStart, customEnd), now)
        let boundedStart = min(customStart, boundedEnd)
        let span = boundedEnd.timeIntervalSince(boundedStart)

        let adapterSource: [String: [String: StatisticsTrafficAmounts]]
        let appSource: [String: [String: StatisticsTrafficAmounts]]
        let relevantKeys: [String]
        let timelineGranularity: StatisticsTimelineGranularity

        let minuteCutoff = calendar.date(byAdding: .minute, value: -Constants.minuteRetentionMinutes, to: now) ?? now
        let hourlyCutoff = calendar.date(byAdding: .hour, value: -Constants.hourlyRetentionHours, to: now) ?? now

        if span <= 3 * 60 * 60, boundedStart >= minuteCutoff {
            adapterSource = archive.adapterMinute
            appSource = archive.appMinute
            relevantKeys = Self.minuteKeys(from: boundedStart, to: boundedEnd, calendar: calendar)
            timelineGranularity = .minute
        } else if span <= 72 * 60 * 60, boundedStart >= hourlyCutoff {
            adapterSource = archive.adapterHourly
            appSource = archive.appHourly
            relevantKeys = Self.hourKeys(from: boundedStart, to: boundedEnd, calendar: calendar)
            timelineGranularity = .hour
        } else {
            adapterSource = archive.adapterDaily
            appSource = archive.appDaily
            relevantKeys = Self.dayKeys(from: boundedStart, to: boundedEnd, calendar: calendar)
            timelineGranularity = span > 90 * 24 * 60 * 60 ? .month : .day
        }

        return makeReport(
            range: .last30Days,
            displayTitle: Self.customRangeTitle(from: boundedStart, to: boundedEnd),
            displayBucketTitle: Self.bucketTitle(for: timelineGranularity),
            timelineGranularity: timelineGranularity,
            timelineStart: boundedStart,
            timelineEnd: boundedEnd,
            adapterSource: adapterSource,
            appSource: appSource,
            relevantKeys: relevantKeys,
            customAdapterNames: customAdapterNames,
            hiddenApps: hiddenApps
        )
    }

    private func makeReport(
        range: StatisticsRange,
        displayTitle: String,
        displayBucketTitle: String,
        timelineGranularity: StatisticsTimelineGranularity,
        timelineStart: Date,
        timelineEnd: Date,
        adapterSource: [String: [String: StatisticsTrafficAmounts]],
        appSource: [String: [String: StatisticsTrafficAmounts]],
        relevantKeys: [String],
        customAdapterNames: [String: String],
        hiddenApps: Set<String>
    ) -> StatisticsReport {
        let coverageStart = earliestCoverageDate()
        let adapterTotals = aggregate(items: adapterSource, keys: relevantKeys)
        let appTotals = aggregate(items: appSource, keys: relevantKeys)
        let timeline = timelinePoints(granularity: timelineGranularity, source: adapterSource, keys: relevantKeys)

        let adapters = topAdapters(from: adapterTotals, customAdapterNames: customAdapterNames)
        let topDownloadApps = appRows(
            from: appTotals,
            hiddenApps: hiddenApps,
            keyPath: \.downloadBytes
        )
        let topUploadApps = appRows(
            from: appTotals,
            hiddenApps: hiddenApps,
            keyPath: \.uploadBytes
        )

        return StatisticsReport(
            range: range,
            displayTitle: displayTitle,
            displayBucketTitle: displayBucketTitle,
            timelineGranularity: timelineGranularity,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd,
            createdAt: archive.createdAt,
            coverageStart: coverageStart,
            lastAdapterSampleAt: archive.lastAdapterSampleAt,
            lastAppSampleAt: archive.lastAppSampleAt,
            totalDownloadBytes: adapterTotals.values.reduce(0) { $0 + $1.downloadBytes },
            totalUploadBytes: adapterTotals.values.reduce(0) { $0 + $1.uploadBytes },
            timeline: timeline,
            adapters: adapters,
            topDownloadApps: topDownloadApps,
            topUploadApps: topUploadApps
        )
    }

    private func aggregate(
        items: [String: [String: StatisticsTrafficAmounts]],
        keys: [String]
    ) -> [String: StatisticsTrafficAmounts] {
        var result: [String: StatisticsTrafficAmounts] = [:]
        for key in keys {
            guard let bucket = items[key] else { continue }
            for (itemKey, amounts) in bucket {
                var current = result[itemKey] ?? StatisticsTrafficAmounts()
                current.merge(amounts)
                result[itemKey] = current
            }
        }
        return result
    }

    private func timelinePoints(
        granularity: StatisticsTimelineGranularity,
        source: [String: [String: StatisticsTrafficAmounts]],
        keys: [String]
    ) -> [StatisticsTimelinePoint] {
        switch granularity {
        case .month:
            var monthlyTotals: [String: StatisticsTrafficAmounts] = [:]
            for key in keys {
                guard let bucketDate = Self.date(fromDayKey: key, calendar: calendar),
                      let bucket = source[key]
                else { continue }
                let monthKey = Self.monthKey(for: bucketDate, calendar: calendar)
                var combined = monthlyTotals[monthKey] ?? StatisticsTrafficAmounts()
                for amounts in bucket.values {
                    combined.merge(amounts)
                }
                monthlyTotals[monthKey] = combined
            }
            return monthlyTotals.keys.sorted().compactMap { key in
                guard let date = Self.date(fromMonthKey: key, calendar: calendar),
                      let totals = monthlyTotals[key]
                else { return nil }
                return StatisticsTimelinePoint(
                    id: key,
                    date: date,
                    downloadBytes: totals.downloadBytes,
                    uploadBytes: totals.uploadBytes
                )
            }
        case .minute, .hour, .day:
            return keys.compactMap { key in
                let date: Date?
                switch granularity {
                case .minute:
                    date = Self.date(fromMinuteKey: key, calendar: calendar)
                case .hour:
                    date = Self.date(fromHourKey: key, calendar: calendar)
                case .day:
                    date = Self.date(fromDayKey: key, calendar: calendar)
                case .month:
                    date = nil
                }
                guard let date, let bucket = source[key] else { return nil }
                let totals = bucket.values.reduce(into: StatisticsTrafficAmounts()) { partial, amounts in
                    partial.merge(amounts)
                }
                return StatisticsTimelinePoint(
                    id: key,
                    date: date,
                    downloadBytes: totals.downloadBytes,
                    uploadBytes: totals.uploadBytes
                )
            }
        }
    }

    private func topAdapters(
        from totals: [String: StatisticsTrafficAmounts],
        customAdapterNames: [String: String]
    ) -> [StatisticsAdapterRow] {
        var rows: [StatisticsAdapterRow] = []
        rows.reserveCapacity(totals.count)
        for (key, amounts) in totals {
            rows.append(
                StatisticsAdapterRow(
                    id: key,
                    name: resolvedAdapterName(id: key, customAdapterNames: customAdapterNames),
                    downloadBytes: amounts.downloadBytes,
                    uploadBytes: amounts.uploadBytes
                )
            )
        }

        let sorted = rows.sorted { lhs, rhs in
            lhs.totalBytes == rhs.totalBytes
                ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                : lhs.totalBytes > rhs.totalBytes
        }

        guard sorted.count > 5 else { return sorted }

        let top = Array(sorted.prefix(5))
        let overflow = sorted.dropFirst(5)
        let overflowDownload = overflow.reduce(0) { $0 + $1.downloadBytes }
        let overflowUpload = overflow.reduce(0) { $0 + $1.uploadBytes }

        guard overflowDownload > 0 || overflowUpload > 0 else { return top }

        return top + [
            StatisticsAdapterRow(
                id: "other",
                name: "Other",
                downloadBytes: overflowDownload,
                uploadBytes: overflowUpload
            )
        ]
    }

    private func appRows(
        from totals: [String: StatisticsTrafficAmounts],
        hiddenApps: Set<String>,
        keyPath: KeyPath<StatisticsTrafficAmounts, UInt64>
    ) -> [StatisticsAppRow] {
        var rows: [StatisticsAppRow] = []
        rows.reserveCapacity(totals.count)

        for (key, amounts) in totals {
            let bytes = amounts[keyPath: keyPath]
            guard !hiddenApps.contains(key), bytes > 0 else { continue }
            rows.append(StatisticsAppRow(id: key, name: key, bytes: bytes))
        }

        return rows
            .sorted { lhs, rhs in
                lhs.bytes == rhs.bytes
                    ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    : lhs.bytes > rhs.bytes
            }
            .prefix(10)
            .map { $0 }
    }

    private func resolvedAdapterName(id: String, customAdapterNames: [String: String]) -> String {
        if let custom = customAdapterNames[id], !custom.isEmpty {
            return custom
        }
        return archive.adapterDisplayNames[id] ?? id
    }

    private func earliestCoverageDate() -> Date? {
        let keys = Array(archive.adapterDaily.keys) + Array(archive.appDaily.keys)
        let dates = keys.compactMap { Self.date(fromDayKey: $0, calendar: calendar) }
        return dates.min() ?? archive.createdAt
    }

    private func accumulate(
        into storage: inout [String: [String: StatisticsTrafficAmounts]],
        bucketKey: String,
        itemKey: String,
        downloadBytes: UInt64,
        uploadBytes: UInt64
    ) {
        var bucket = storage[bucketKey] ?? [:]
        var current = bucket[itemKey] ?? StatisticsTrafficAmounts()
        current.add(downloadBytes: downloadBytes, uploadBytes: uploadBytes)
        bucket[itemKey] = current
        storage[bucketKey] = bucket
    }

    private func prune(now: Date) {
        let minuteCutoff = calendar.date(byAdding: .minute, value: -Constants.minuteRetentionMinutes, to: now) ?? now
        let hourlyCutoff = calendar.date(byAdding: .hour, value: -Constants.hourlyRetentionHours, to: now) ?? now
        let dailyCutoff = calendar.date(byAdding: .day, value: -Constants.dailyRetentionDays, to: now) ?? now

        archive.adapterMinute = archive.adapterMinute.filter { key, _ in
            guard let date = Self.date(fromMinuteKey: key, calendar: calendar) else { return false }
            return date >= minuteCutoff
        }
        archive.appMinute = archive.appMinute.filter { key, _ in
            guard let date = Self.date(fromMinuteKey: key, calendar: calendar) else { return false }
            return date >= minuteCutoff
        }
        archive.adapterHourly = archive.adapterHourly.filter { key, _ in
            guard let date = Self.date(fromHourKey: key, calendar: calendar) else { return false }
            return date >= hourlyCutoff
        }
        archive.appHourly = archive.appHourly.filter { key, _ in
            guard let date = Self.date(fromHourKey: key, calendar: calendar) else { return false }
            return date >= hourlyCutoff
        }
        archive.adapterDaily = archive.adapterDaily.filter { key, _ in
            guard let date = Self.date(fromDayKey: key, calendar: calendar) else { return false }
            return date >= dailyCutoff
        }
        archive.appDaily = archive.appDaily.filter { key, _ in
            guard let date = Self.date(fromDayKey: key, calendar: calendar) else { return false }
            return date >= dailyCutoff
        }
    }

    private func saveIfNeeded(now: Date) {
        guard hasPendingChanges else { return }
        if lastFlushAt == nil || now.timeIntervalSince(lastFlushAt ?? now) >= Constants.flushInterval {
            save()
        }
    }

    private func save() {
        guard let url else {
            hasPendingChanges = false
            lastFlushAt = Date()
            return
        }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(archive)
            try data.write(to: url, options: [.atomic])
            hasPendingChanges = false
            lastFlushAt = Date()
        } catch {
            // Keep data in memory; the next flush attempt may succeed.
        }
    }

    private static func loadArchive(from url: URL) -> (archive: StatisticsArchive, didMigrate: Bool) {
        guard
            let data = try? Data(contentsOf: url),
            let archive = try? decodedArchive(from: data)
        else {
            return (.empty, false)
        }
        return migrateArchiveIfNeeded(archive)
    }

    private static func migrateArchiveIfNeeded(_ archive: StatisticsArchive) -> (archive: StatisticsArchive, didMigrate: Bool) {
        var archive = archive
        var didMigrate = false

        if archive.appTrafficSchemaVersion < StatisticsArchive.currentAppTrafficSchemaVersion {
            archive.appMinute = [:]
            archive.appHourly = [:]
            archive.appDaily = [:]
            archive.lastAppSampleAt = nil
            archive.appTrafficSchemaVersion = StatisticsArchive.currentAppTrafficSchemaVersion
            didMigrate = true
        }

        return (archive, didMigrate)
    }

    private static func decodedArchive(from data: Data) throws -> StatisticsArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StatisticsArchive.self, from: data)
    }

    private static func customRangeTitle(from start: Date, to end: Date) -> String {
        let startText = start.formatted(date: .abbreviated, time: .shortened)
        let endText = end.formatted(date: .abbreviated, time: .shortened)
        return "\(startText) – \(endText)"
    }

    private static func bucketTitle(for granularity: StatisticsTimelineGranularity) -> String {
        switch granularity {
        case .minute:
            return "Minute Traffic"
        case .hour:
            return "Hourly Traffic"
        case .day:
            return "Daily Traffic"
        case .month:
            return "Monthly Traffic"
        }
    }

    private static func hourKeys(endingAt date: Date, count: Int, calendar: Calendar) -> [String] {
        let end = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        return (0..<count).compactMap { offset in
            let bucketDate = calendar.date(byAdding: .hour, value: -(count - 1 - offset), to: end)
            return bucketDate.map { hourKey(for: $0, calendar: calendar) }
        }
    }

    private static func minuteKeys(endingAt date: Date, count: Int, calendar: Calendar) -> [String] {
        let end = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        return (0..<count).compactMap { offset in
            let bucketDate = calendar.date(byAdding: .minute, value: -(count - 1 - offset), to: end)
            return bucketDate.map { minuteKey(for: $0, calendar: calendar) }
        }
    }

    private static func dayKeys(endingAt date: Date, count: Int, calendar: Calendar) -> [String] {
        let end = calendar.startOfDay(for: date)
        return (0..<count).compactMap { offset in
            let bucketDate = calendar.date(byAdding: .day, value: -(count - 1 - offset), to: end)
            return bucketDate.map { dayKey(for: $0, calendar: calendar) }
        }
    }

    private static func hourKeys(from start: Date, to end: Date, calendar: Calendar) -> [String] {
        let startHour = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        let endHour = calendar.dateInterval(of: .hour, for: end)?.start ?? end
        var keys: [String] = []
        var current = startHour
        let includeEndHour = end != endHour

        while includeEndHour ? current <= endHour : current < endHour {
            keys.append(hourKey(for: current, calendar: calendar))
            guard let next = calendar.date(byAdding: .hour, value: 1, to: current) else { break }
            current = next
        }

        return keys
    }

    private static func minuteKeys(from start: Date, to end: Date, calendar: Calendar) -> [String] {
        let startMinute = calendar.dateInterval(of: .minute, for: start)?.start ?? start
        let endMinute = calendar.dateInterval(of: .minute, for: end)?.start ?? end
        var keys: [String] = []
        var current = startMinute

        while current <= endMinute {
            keys.append(minuteKey(for: current, calendar: calendar))
            guard let next = calendar.date(byAdding: .minute, value: 1, to: current) else { break }
            current = next
        }

        return keys
    }

    private static func dayKeys(from start: Date, to end: Date, calendar: Calendar) -> [String] {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        var keys: [String] = []
        var current = startDay

        while current <= endDay {
            keys.append(dayKey(for: current, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }

        return keys
    }

    private static func hourKey(for date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return String(format: "%04d-%02d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0, comps.hour ?? 0)
    }

    private static func minuteKey(for date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d-%02d-%02d",
            comps.year ?? 0,
            comps.month ?? 0,
            comps.day ?? 0,
            comps.hour ?? 0,
            comps.minute ?? 0
        )
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private static func monthKey(for date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    private static func date(fromHourKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3]))
    }

    private static func date(fromMinuteKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 5 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4]))
    }

    private static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func date(fromMonthKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
    }
}
