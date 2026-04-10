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

enum StatisticsDemoData {
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private struct AdapterProfile {
        let id: String
        let name: String
        let dailyDownloadMB: ClosedRange<Double>
        let dailyUploadMB: ClosedRange<Double>
        let hourlyWeight: Double
        let weekdayBias: Double
        let weekendBias: Double
    }

    private struct AppProfile {
        let name: String
        let dailyDownloadMB: ClosedRange<Double>
        let dailyUploadMB: ClosedRange<Double>
        let hourlyWeight: Double
        let weekdayBias: Double
        let weekendBias: Double
    }

    static func makeArchive(now: Date, calendar: Calendar = .autoupdatingCurrent) -> StatisticsArchive {
        let startOfToday = calendar.startOfDay(for: now)
        let oldestDay = calendar.date(byAdding: .day, value: -364, to: startOfToday) ?? startOfToday

        let adapters = adapterProfiles
        let apps = appProfiles

        var archive = StatisticsArchive.empty
        archive.createdAt = oldestDay
        archive.lastAdapterSampleAt = calendar.date(byAdding: .minute, value: -2, to: now)
        archive.lastAppSampleAt = calendar.date(byAdding: .minute, value: -2, to: now)
        archive.adapterDisplayNames = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, $0.name) })

        var generator = SeededGenerator(seed: 0x4E6574466C757373)

        for dayOffset in 0..<365 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: oldestDay) else { continue }
            let dayKey = Self.dayKey(for: date, calendar: calendar)
            let weekdayFactor = isWeekend(date, calendar: calendar) ? 0.78 : 1.0
            let seasonFactor = seasonality(for: date, calendar: calendar)

            for profile in adapters where adapterIsActive(profile, on: date, calendar: calendar) {
                let downloadMB = sampledValue(
                    from: profile.dailyDownloadMB,
                    seasonFactor: seasonFactor * (isWeekend(date, calendar: calendar) ? profile.weekendBias : profile.weekdayBias),
                    randomScale: Double.random(in: 0.88...1.14, using: &generator)
                )
                let uploadMB = sampledValue(
                    from: profile.dailyUploadMB,
                    seasonFactor: seasonFactor * weekdayFactor * Double.random(in: 0.90...1.12, using: &generator),
                    randomScale: 1.0
                )
                accumulate(
                    into: &archive.adapterDaily,
                    bucketKey: dayKey,
                    itemKey: profile.id,
                    downloadBytes: bytes(fromMegabytes: downloadMB),
                    uploadBytes: bytes(fromMegabytes: uploadMB)
                )
            }

            for profile in apps where appIsActive(profile, on: date, calendar: calendar) {
                let downloadMB = sampledValue(
                    from: profile.dailyDownloadMB,
                    seasonFactor: seasonFactor * (isWeekend(date, calendar: calendar) ? profile.weekendBias : profile.weekdayBias),
                    randomScale: Double.random(in: 0.86...1.16, using: &generator)
                )
                let uploadMB = sampledValue(
                    from: profile.dailyUploadMB,
                    seasonFactor: seasonFactor * weekdayFactor * Double.random(in: 0.88...1.15, using: &generator),
                    randomScale: 1.0
                )
                accumulate(
                    into: &archive.appDaily,
                    bucketKey: dayKey,
                    itemKey: profile.name,
                    downloadBytes: bytes(fromMegabytes: downloadMB),
                    uploadBytes: bytes(fromMegabytes: uploadMB)
                )
            }
        }

        let oldestHour = calendar.date(byAdding: .hour, value: -71, to: calendar.dateInterval(of: .hour, for: now)?.start ?? now)
            ?? now

        for hourOffset in 0..<72 {
            guard let date = calendar.date(byAdding: .hour, value: hourOffset, to: oldestHour) else { continue }
            let hourKey = Self.hourKey(for: date, calendar: calendar)
            let hourFactor = hourlyFactor(for: date, calendar: calendar)
            let seasonFactor = seasonality(for: date, calendar: calendar)

            for profile in adapters where adapterIsActive(profile, on: date, calendar: calendar) {
                let downloadMB = sampledHourlyValue(
                    from: profile.dailyDownloadMB,
                    weight: profile.hourlyWeight,
                    hourFactor: hourFactor,
                    seasonFactor: seasonFactor,
                    randomScale: Double.random(in: 0.82...1.18, using: &generator)
                )
                let uploadMB = sampledHourlyValue(
                    from: profile.dailyUploadMB,
                    weight: profile.hourlyWeight,
                    hourFactor: hourFactor * 0.92,
                    seasonFactor: seasonFactor,
                    randomScale: Double.random(in: 0.84...1.16, using: &generator)
                )
                accumulate(
                    into: &archive.adapterHourly,
                    bucketKey: hourKey,
                    itemKey: profile.id,
                    downloadBytes: bytes(fromMegabytes: downloadMB),
                    uploadBytes: bytes(fromMegabytes: uploadMB)
                )
            }

            for profile in apps where appIsActive(profile, on: date, calendar: calendar) {
                let downloadMB = sampledHourlyValue(
                    from: profile.dailyDownloadMB,
                    weight: profile.hourlyWeight,
                    hourFactor: hourFactor,
                    seasonFactor: seasonFactor,
                    randomScale: Double.random(in: 0.80...1.20, using: &generator)
                )
                let uploadMB = sampledHourlyValue(
                    from: profile.dailyUploadMB,
                    weight: profile.hourlyWeight,
                    hourFactor: hourFactor * 0.9,
                    seasonFactor: seasonFactor,
                    randomScale: Double.random(in: 0.82...1.18, using: &generator)
                )
                accumulate(
                    into: &archive.appHourly,
                    bucketKey: hourKey,
                    itemKey: profile.name,
                    downloadBytes: bytes(fromMegabytes: downloadMB),
                    uploadBytes: bytes(fromMegabytes: uploadMB)
                )
            }
        }

        let oldestMinute = calendar.date(byAdding: .minute, value: -179, to: calendar.dateInterval(of: .minute, for: now)?.start ?? now)
            ?? now

        for minuteOffset in 0..<180 {
            guard let date = calendar.date(byAdding: .minute, value: minuteOffset, to: oldestMinute) else { continue }
            let minuteKey = Self.minuteKey(for: date, calendar: calendar)
            let minuteFactor = minuteTrafficFactor(for: date, calendar: calendar)
            let hourFactor = hourlyFactor(for: date, calendar: calendar)
            let seasonFactor = seasonality(for: date, calendar: calendar)

            for profile in adapters where adapterIsActive(profile, on: date, calendar: calendar) {
                let downloadMB = sampledMinuteValue(
                    from: profile.dailyDownloadMB,
                    weight: profile.hourlyWeight,
                    hourFactor: hourFactor,
                    minuteFactor: minuteFactor,
                    seasonFactor: seasonFactor,
                    randomScale: Double.random(in: 0.78...1.22, using: &generator)
                )
                let uploadMB = sampledMinuteValue(
                    from: profile.dailyUploadMB,
                    weight: profile.hourlyWeight,
                    hourFactor: hourFactor * 0.9,
                    minuteFactor: minuteFactor,
                    seasonFactor: seasonFactor,
                    randomScale: Double.random(in: 0.80...1.20, using: &generator)
                )
                accumulate(
                    into: &archive.adapterMinute,
                    bucketKey: minuteKey,
                    itemKey: profile.id,
                    downloadBytes: bytes(fromMegabytes: downloadMB),
                    uploadBytes: bytes(fromMegabytes: uploadMB)
                )
            }

            for profile in apps where appIsActive(profile, on: date, calendar: calendar) {
                let downloadMB = sampledMinuteValue(
                    from: profile.dailyDownloadMB,
                    weight: profile.hourlyWeight,
                    hourFactor: hourFactor,
                    minuteFactor: minuteFactor,
                    seasonFactor: seasonFactor,
                    randomScale: Double.random(in: 0.76...1.24, using: &generator)
                )
                let uploadMB = sampledMinuteValue(
                    from: profile.dailyUploadMB,
                    weight: profile.hourlyWeight,
                    hourFactor: hourFactor * 0.88,
                    minuteFactor: minuteFactor,
                    seasonFactor: seasonFactor,
                    randomScale: Double.random(in: 0.78...1.22, using: &generator)
                )
                accumulate(
                    into: &archive.appMinute,
                    bucketKey: minuteKey,
                    itemKey: profile.name,
                    downloadBytes: bytes(fromMegabytes: downloadMB),
                    uploadBytes: bytes(fromMegabytes: uploadMB)
                )
            }
        }

        return archive
    }

    private static let adapterProfiles: [AdapterProfile] = [
        AdapterProfile(id: "en0", name: "Wi-Fi", dailyDownloadMB: 4_200...8_800, dailyUploadMB: 620...1_450, hourlyWeight: 1.18, weekdayBias: 1.08, weekendBias: 0.78),
        AdapterProfile(id: "en5", name: "USB-C Ethernet", dailyDownloadMB: 1_000...3_800, dailyUploadMB: 350...1_120, hourlyWeight: 0.94, weekdayBias: 1.12, weekendBias: 0.42),
        AdapterProfile(id: "utun3", name: "Work VPN", dailyDownloadMB: 780...2_450, dailyUploadMB: 420...1_480, hourlyWeight: 0.82, weekdayBias: 1.18, weekendBias: 0.18),
        AdapterProfile(id: "bridge0", name: "Docker Bridge", dailyDownloadMB: 260...940, dailyUploadMB: 140...620, hourlyWeight: 0.56, weekdayBias: 1.06, weekendBias: 0.34),
        AdapterProfile(id: "en7", name: "iPhone Hotspot", dailyDownloadMB: 90...620, dailyUploadMB: 40...220, hourlyWeight: 0.34, weekdayBias: 0.48, weekendBias: 0.62),
        AdapterProfile(id: "awdl0", name: "AirDrop", dailyDownloadMB: 20...180, dailyUploadMB: 8...110, hourlyWeight: 0.22, weekdayBias: 0.18, weekendBias: 0.24)
    ]

    private static let appProfiles: [AppProfile] = [
        AppProfile(name: "Arc", dailyDownloadMB: 680...1_950, dailyUploadMB: 120...360, hourlyWeight: 1.08, weekdayBias: 1.04, weekendBias: 0.92),
        AppProfile(name: "Safari", dailyDownloadMB: 520...1_620, dailyUploadMB: 80...220, hourlyWeight: 0.96, weekdayBias: 0.92, weekendBias: 1.04),
        AppProfile(name: "Spotify", dailyDownloadMB: 260...1_080, dailyUploadMB: 18...48, hourlyWeight: 0.74, weekdayBias: 0.88, weekendBias: 1.18),
        AppProfile(name: "Slack", dailyDownloadMB: 180...520, dailyUploadMB: 90...260, hourlyWeight: 0.72, weekdayBias: 1.15, weekendBias: 0.42),
        AppProfile(name: "Microsoft Teams", dailyDownloadMB: 220...680, dailyUploadMB: 180...640, hourlyWeight: 0.78, weekdayBias: 1.20, weekendBias: 0.28),
        AppProfile(name: "Zoom", dailyDownloadMB: 160...540, dailyUploadMB: 220...760, hourlyWeight: 0.74, weekdayBias: 1.14, weekendBias: 0.26),
        AppProfile(name: "Photos", dailyDownloadMB: 120...460, dailyUploadMB: 160...920, hourlyWeight: 0.42, weekdayBias: 0.72, weekendBias: 1.08),
        AppProfile(name: "Xcode", dailyDownloadMB: 140...510, dailyUploadMB: 50...180, hourlyWeight: 0.64, weekdayBias: 1.12, weekendBias: 0.22),
        AppProfile(name: "GitHub Desktop", dailyDownloadMB: 110...380, dailyUploadMB: 90...340, hourlyWeight: 0.58, weekdayBias: 1.10, weekendBias: 0.26),
        AppProfile(name: "Dropbox", dailyDownloadMB: 140...420, dailyUploadMB: 130...520, hourlyWeight: 0.48, weekdayBias: 0.94, weekendBias: 0.88),
        AppProfile(name: "App Store", dailyDownloadMB: 40...740, dailyUploadMB: 4...14, hourlyWeight: 0.24, weekdayBias: 0.78, weekendBias: 0.64),
        AppProfile(name: "Figma", dailyDownloadMB: 90...320, dailyUploadMB: 60...260, hourlyWeight: 0.44, weekdayBias: 1.06, weekendBias: 0.36)
    ]

    private static func accumulate(
        into storage: inout [String: [String: StatisticsTrafficAmounts]],
        bucketKey: String,
        itemKey: String,
        downloadBytes: UInt64,
        uploadBytes: UInt64
    ) {
        guard downloadBytes > 0 || uploadBytes > 0 else { return }
        var bucket = storage[bucketKey] ?? [:]
        var current = bucket[itemKey] ?? StatisticsTrafficAmounts()
        current.add(downloadBytes: downloadBytes, uploadBytes: uploadBytes)
        bucket[itemKey] = current
        storage[bucketKey] = bucket
    }

    private static func sampledValue(
        from range: ClosedRange<Double>,
        seasonFactor: Double,
        randomScale: Double
    ) -> Double {
        let midpoint = (range.lowerBound + range.upperBound) / 2
        let spread = (range.upperBound - range.lowerBound) / 2
        let value = midpoint + spread * (randomScale - 1.0) * 2.0
        return max(value * seasonFactor, 1)
    }

    private static func sampledHourlyValue(
        from dailyRange: ClosedRange<Double>,
        weight: Double,
        hourFactor: Double,
        seasonFactor: Double,
        randomScale: Double
    ) -> Double {
        let dailyMidpoint = (dailyRange.lowerBound + dailyRange.upperBound) / 2
        return max((dailyMidpoint / 24.0) * weight * hourFactor * seasonFactor * randomScale, 0.2)
    }

    private static func sampledMinuteValue(
        from dailyRange: ClosedRange<Double>,
        weight: Double,
        hourFactor: Double,
        minuteFactor: Double,
        seasonFactor: Double,
        randomScale: Double
    ) -> Double {
        let dailyMidpoint = (dailyRange.lowerBound + dailyRange.upperBound) / 2
        return max((dailyMidpoint / (24.0 * 60.0)) * weight * hourFactor * minuteFactor * seasonFactor * randomScale, 0.01)
    }

    private static func bytes(fromMegabytes megabytes: Double) -> UInt64 {
        UInt64((megabytes * 1_000_000.0).rounded())
    }

    private static func seasonality(for date: Date, calendar: Calendar) -> Double {
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let yearlyWave = sin((dayOfYear / 365.0) * 2.0 * .pi)
        let monthlyWave = cos((dayOfYear / 30.0) * 2.0 * .pi)
        return max(0.62, 1.0 + yearlyWave * 0.16 + monthlyWave * 0.05)
    }

    private static func hourlyFactor(for date: Date, calendar: Calendar) -> Double {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 0..<6:
            return 0.18
        case 6..<8:
            return 0.42
        case 8..<12:
            return 1.0
        case 12..<14:
            return 0.82
        case 14..<18:
            return 1.08
        case 18..<22:
            return 0.68
        default:
            return 0.34
        }
    }

    private static func minuteTrafficFactor(for date: Date, calendar: Calendar) -> Double {
        let minute = calendar.component(.minute, from: date)
        switch minute {
        case 0..<10:
            return 0.72
        case 10..<20:
            return 0.94
        case 20..<35:
            return 1.18
        case 35..<45:
            return 1.04
        case 45..<55:
            return 0.88
        default:
            return 0.76
        }
    }

    private static func adapterIsActive(_ profile: AdapterProfile, on date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1

        switch profile.id {
        case "en0":
            return true
        case "en5":
            return weekday != 1 && weekday != 7 && dayOfYear % 9 != 0
        case "utun3":
            return weekday != 1 && weekday != 7 && dayOfYear % 6 != 0
        case "bridge0":
            return weekday != 1 && dayOfYear % 5 != 0
        case "en7":
            return dayOfYear % 17 == 0 || dayOfYear % 29 == 0
        case "awdl0":
            return dayOfYear % 23 == 0 || dayOfYear % 41 == 0
        default:
            return true
        }
    }

    private static func appIsActive(_ profile: AppProfile, on date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1

        switch profile.name {
        case "Microsoft Teams", "Zoom", "Slack", "Xcode", "GitHub Desktop", "Figma":
            return weekday != 1 && weekday != 7 && dayOfYear % 8 != 0
        case "App Store":
            return dayOfYear % 13 == 0 || dayOfYear % 27 == 0
        case "Spotify", "Safari", "Photos":
            return true
        default:
            return dayOfYear % 11 != 0
        }
    }

    private static func isWeekend(_ date: Date, calendar: Calendar) -> Bool {
        calendar.isDateInWeekend(date)
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
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
}
