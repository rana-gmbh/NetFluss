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

import Combine
import Foundation

@MainActor
final class StatisticsManager: ObservableObject {
    private enum Constants {
        // App sampling spawns `netstat` and parses its (~185 KB) output, so it is
        // the main background cost. Sample infrequently — these are historical
        // rollups, not live data (the popover's live Top Apps uses its own path).
        static let appSamplingInterval: TimeInterval = 20
        static let lowPowerAppSamplingInterval: TimeInterval = 60
        /// Skip an app sample unless at least this many bytes moved since the last
        /// one, so idle periods spawn no netstat at all.
        static let appSampleByteThreshold: UInt64 = 256 * 1024
    }

    @Published private(set) var report: StatisticsReport?
    @Published private(set) var isLoading = false
    @Published private(set) var isShowingSampleData = false

    private let monitor: NetworkMonitor
    private let store: StatisticsStore
    private var sampleStore: StatisticsStore?
    private var cancellables: Set<AnyCancellable> = []
    private var previousAdapterSnapshot: [String: (downloadBytes: UInt64, uploadBytes: UInt64)] = [:]
    private var previousAppSnapshot: [String: ProcessConnectionSnapshot] = [:]
    private var previousAppSampleTime: Date?
    /// Adapter bytes seen since the last app sample; gates the netstat spawn.
    private var bytesSinceLastAppSample: UInt64 = 0
    private let appSamplingQueue = DispatchQueue(label: "com.local.netfluss.statistics.apps", qos: .utility)
    private var appSamplingTimer: DispatchSourceTimer?
    private var appSamplingInFlight = false
    private var currentRange: StatisticsRange = .last24Hours
    private var currentCustomStart: Date?
    private var currentCustomEnd: Date?

    init(monitor: NetworkMonitor) {
        self.monitor = monitor
        self.store = StatisticsStore(url: Self.storageURL())

        monitor.$adapters
            .receive(on: DispatchQueue.main)
            .sink { [weak self] adapters in
                self?.ingestAdapterSnapshot(adapters)
            }
            .store(in: &cancellables)

        applyPreferences()

        if Self.sampleDataEnabledForLaunch {
            enableSampleData()
        }
    }

    var monitoredNetwork: NetworkMonitor { monitor }
    var sampleDataControlsEnabled: Bool { Self.sampleDataEnabledForLaunch }

    func applyPreferences() {
        if statisticsEnabled && appStatisticsEnabled {
            startAppSampling()
        } else {
            stopAppSampling()
        }

        if !statisticsEnabled {
            previousAdapterSnapshot = snapshotMap(from: monitor.adapters)
        }
        if !appStatisticsEnabled {
            previousAppSnapshot = [:]
            previousAppSampleTime = nil
        }
    }

    func loadReport(for range: StatisticsRange) {
        currentRange = range
        currentCustomStart = nil
        currentCustomEnd = nil
        isLoading = true

        let customAdapterNames = Self.loadAdapterNames()
        let hiddenApps = Set(UserDefaults.standard.stringArray(forKey: "hiddenApps") ?? [])
        let activeStore = isShowingSampleData ? (sampleStore ?? store) : store

        Task { [activeStore] in
            let report = await activeStore.report(
                for: range,
                now: Date(),
                customAdapterNames: customAdapterNames,
                hiddenApps: hiddenApps
            )
            await MainActor.run {
                self.report = report
                self.isLoading = false
            }
        }
    }

    func loadReport(customStart: Date, customEnd: Date) {
        currentCustomStart = customStart
        currentCustomEnd = customEnd
        isLoading = true

        let customAdapterNames = Self.loadAdapterNames()
        let hiddenApps = Set(UserDefaults.standard.stringArray(forKey: "hiddenApps") ?? [])
        let activeStore = isShowingSampleData ? (sampleStore ?? store) : store

        Task { [activeStore] in
            let report = await activeStore.report(
                customStart: customStart,
                customEnd: customEnd,
                now: Date(),
                customAdapterNames: customAdapterNames,
                hiddenApps: hiddenApps
            )
            await MainActor.run {
                self.report = report
                self.isLoading = false
            }
        }
    }

    func refreshCurrentReport() {
        if let currentCustomStart, let currentCustomEnd {
            loadReport(customStart: currentCustomStart, customEnd: currentCustomEnd)
        } else {
            loadReport(for: currentRange)
        }
    }

    func enableSampleData() {
        sampleStore = StatisticsStore(archive: StatisticsDemoData.makeArchive(now: Date()))
        isShowingSampleData = true
        refreshCurrentReport()
    }

    func disableSampleData() {
        sampleStore = nil
        isShowingSampleData = false
        refreshCurrentReport()
    }

    func flushSynchronously() {
        let group = DispatchGroup()
        group.enter()
        Task.detached { [store] in
            await store.flush(force: true)
            group.leave()
        }
        _ = group.wait(timeout: .now() + 2.0)
    }

    private var statisticsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "collectStatistics")
    }

    private var appStatisticsEnabled: Bool {
        statisticsEnabled && UserDefaults.standard.bool(forKey: "collectAppStatistics")
    }

    private func ingestAdapterSnapshot(_ adapters: [AdapterStatus]) {
        let currentSnapshot = snapshotMap(from: adapters)
        guard statisticsEnabled else {
            previousAdapterSnapshot = currentSnapshot
            return
        }
        guard !previousAdapterSnapshot.isEmpty else {
            previousAdapterSnapshot = currentSnapshot
            return
        }

        let deltas = adapters.compactMap { adapter -> StatisticsAdapterDelta? in
            let previous = previousAdapterSnapshot[adapter.id]
            let downloadDelta = delta(current: adapter.rxBytes, previous: previous?.downloadBytes)
            let uploadDelta = delta(current: adapter.txBytes, previous: previous?.uploadBytes)
            guard downloadDelta > 0 || uploadDelta > 0 else { return nil }
            return StatisticsAdapterDelta(
                id: adapter.id,
                displayName: adapter.displayName,
                downloadBytes: downloadDelta,
                uploadBytes: uploadDelta
            )
        }

        previousAdapterSnapshot = currentSnapshot
        bytesSinceLastAppSample &+= deltas.reduce(UInt64(0)) { $0 &+ $1.downloadBytes &+ $1.uploadBytes }
        guard !deltas.isEmpty else { return }

        Task.detached(priority: .utility) { [store] in
            await store.recordAdapterDeltas(deltas, at: Date())
        }
    }

    private func startAppSampling() {
        guard appSamplingTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: appSamplingQueue)
        let interval = ProcessInfo.processInfo.isLowPowerModeEnabled
            ? Constants.lowPowerAppSamplingInterval
            : Constants.appSamplingInterval
        let leeway = DispatchTimeInterval.seconds(Int(interval / 6))
        timer.schedule(deadline: .now() + 5.0, repeating: interval, leeway: leeway)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.runAppSampleIfNeeded()
            }
        }
        timer.resume()
        appSamplingTimer = timer
    }

    private func stopAppSampling() {
        appSamplingTimer?.cancel()
        appSamplingTimer = nil
        appSamplingInFlight = false
        previousAppSnapshot = [:]
        previousAppSampleTime = nil
    }

    private func runAppSampleIfNeeded() {
        guard appStatisticsEnabled, !appSamplingInFlight else { return }
        // Skip the netstat-spawning sample when traffic since the last one was
        // negligible — idle periods then cost nothing. The counter accumulates
        // across skips, so a quiet stretch still samples once it adds up.
        guard bytesSinceLastAppSample >= Constants.appSampleByteThreshold else { return }
        bytesSinceLastAppSample = 0
        appSamplingInFlight = true

        Task { [weak self] in
            let sampleTime = Date()
            let sample = await Task.detached(priority: .utility) {
                ProcessNetworkSampler.sampleStatisticsAppTraffic()
            }.value

            guard let self else { return }
            self.appSamplingInFlight = false
            guard self.appStatisticsEnabled else {
                self.previousAppSnapshot = [:]
                self.previousAppSampleTime = sampleTime
                return
            }

            switch sample {
            case .directDeltas(let totalsByName):
                let deltas = totalsByName.compactMap { name, totals -> StatisticsAppDelta? in
                    guard totals.rx > 0 || totals.tx > 0 else { return nil }
                    return StatisticsAppDelta(
                        name: name,
                        downloadBytes: totals.rx,
                        uploadBytes: totals.tx
                    )
                }

                if !deltas.isEmpty {
                    Task.detached(priority: .utility) { [store] in
                        await store.recordAppDeltas(deltas, at: sampleTime)
                    }
                }

                self.previousAppSnapshot = [:]
                self.previousAppSampleTime = sampleTime

            case .snapshot(let snapshot):
                let previousSnapshot = self.previousAppSnapshot
                let previousTime = self.previousAppSampleTime

                if let previousTime, !previousSnapshot.isEmpty, sampleTime.timeIntervalSince(previousTime) >= 1 {
                    let deltas = ProcessNetworkSampler.appDeltas(current: snapshot, previous: previousSnapshot).compactMap {
                        name, totals -> StatisticsAppDelta? in
                        guard totals.rx > 0 || totals.tx > 0 else { return nil }
                        return StatisticsAppDelta(
                            name: name,
                            downloadBytes: totals.rx,
                            uploadBytes: totals.tx
                        )
                    }

                    if !deltas.isEmpty {
                        Task.detached(priority: .utility) { [store] in
                            await store.recordAppDeltas(deltas, at: sampleTime)
                        }
                    }
                }

                self.previousAppSnapshot = snapshot
                self.previousAppSampleTime = sampleTime
            }
        }
    }

    private func snapshotMap(from adapters: [AdapterStatus]) -> [String: (downloadBytes: UInt64, uploadBytes: UInt64)] {
        Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, (downloadBytes: $0.rxBytes, uploadBytes: $0.txBytes)) })
    }

    private func delta(current: UInt64, previous: UInt64?) -> UInt64 {
        guard let previous else { return 0 }
        // Interface counters can reset when macOS recreates an adapter after
        // sleep, reboot, dock reconnects, or link changes. Treat that as a new
        // baseline; adding `current` here would duplicate traffic and inflate
        // adapter history.
        guard current >= previous else { return 0 }
        return current - previous
    }

    private static func storageURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("NetFluss", isDirectory: true)
            .appendingPathComponent("statistics.json", isDirectory: false)
    }

    private static func loadAdapterNames() -> [String: String] {
        guard
            let data = UserDefaults.standard.data(forKey: "adapterCustomNames"),
            let names = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return names
    }

    static var appSamplingIntervalDescription: String {
        let interval = ProcessInfo.processInfo.isLowPowerModeEnabled
            ? Constants.lowPowerAppSamplingInterval
            : Constants.appSamplingInterval
        return "\(Int(interval)) s"
    }

    private static var sampleDataEnabledForLaunch: Bool {
        ProcessInfo.processInfo.environment["NETFLUSS_SAMPLE_STATISTICS"] == "1"
    }
}
