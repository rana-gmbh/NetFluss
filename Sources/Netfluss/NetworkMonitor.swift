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

import CoreWLAN
import AppKit
import Foundation
import PrivilegedExecution
import Security
import SystemConfiguration

@MainActor
final class NetworkMonitor: NSObject, ObservableObject {
    @Published var adapters: [AdapterStatus] = []
    @Published var totals = RateTotals(rxRateBps: 0, txRateBps: 0)
    @Published var topApps: [AppTraffic] = []
    @Published var reconnectingAdapters: Set<String> = []
    @Published var adapterGraceDeadlines: [String: Date] = [:]
    @Published var internalIP: String = "—"
    @Published var gatewayIP: String = "—"
    @Published var externalIP: String = "—"
    @Published var externalIPCountryCode: String = ""
    @Published var recentAppNames: [String] = []
    @Published var currentDNSServers: [String] = []
    @Published var activeDNSPresetID: String? = nil
    @Published var dnsChanging = false
    @Published var dnsError: String?
    @Published var fritzBox: FritzBoxBandwidth?
    @Published var fritzBoxMaxDown: UInt64 = 0
    @Published var fritzBoxMaxUp: UInt64 = 0
    @Published var fritzBoxError: String?
    @Published var unifi: UniFiBandwidth?
    @Published var unifiError: String?
    @Published var openWRT: OpenWRTBandwidth?
    @Published var openWRTError: String?

    private var timer: DispatchSourceTimer?
    private let refreshQueue = DispatchQueue(label: "com.local.netfluss.refresh", qos: .utility)
    private var fritzBoxInFlight = false
    private var fritzBoxLinkFetched = false
    private var fritzBoxFailureCount = 0
    private var unifiInFlight = false
    private var openWRTInFlight = false
    private var openWRTLastSample: OpenWRTSample?
    private var lastSample: [String: InterfaceSample] = [:]
    private var lastUpdate: Date?
    private var currentInterval: Double?
    private var lastExternalIPUpdate: Date?
    private var externalIPInFlight = false
    private var lastExternalIPv6Setting: Bool?
    private var processSnapshot: [String: ProcessConnectionSnapshot] = [:]
    private var processSnapshotTime: Date?
    private var topAppsTaskInFlight = false
    private var adapterLastActiveTime: [String: Date] = [:]
    private var topAppLastActiveTime: [String: (lastSeen: Date, rxRate: Double, txRate: Double)] = [:]
    private var allAppLastSeen: [String: Date] = [:]
    private var refreshInFlight = false
    private var detailMonitoringEnabled = false
    private var forceDetailRefresh = false
    private var detailMonitoringGeneration: UInt64 = 0
    private var lastInterfaceInfoRefresh: Date?
    private var lastWiFiDetailsRefresh: Date?
    private var lastTopAppsRefresh: Date?
    private var lastAddressDetailsRefresh: Date?
    private var lastDNSRefresh: Date?
    private var lastRouterRefresh: Date?

    // Cached interface info (type/displayName) — rarely changes
    private var cachedInterfaceInfo: [String: InterfaceSampler.InterfaceInfo] = [:]
    // Reusable SCDynamicStore
    private lazy var dynamicStore: SCDynamicStore? = SCDynamicStoreCreate(nil, "NetFluss" as CFString, nil, nil)
    // Cached Wi-Fi info
    private var _cachedWifiInfo: [String: InterfaceSampler.WifiInfo] = [:]
    private let wifiClient = CWWiFiClient.shared()

    private static let interfaceInfoRefreshInterval: TimeInterval = 30
    private static let wifiDetailsRefreshInterval: TimeInterval = 15
    private static let topAppsRefreshInterval: TimeInterval = 5
    private static let addressDetailsRefreshInterval: TimeInterval = 15
    private static let dnsRefreshInterval: TimeInterval = 30
    private static let routerRefreshInterval: TimeInterval = 5
    private static let externalIPRefreshInterval: TimeInterval = 300
    private static let fritzBoxFailureThreshold = 3

    private struct RefreshResult {
        let adapters: [AdapterStatus]
        let totals: RateTotals
        let samplesByName: [String: InterfaceSample]
        let interfaceInfo: [String: InterfaceSampler.InterfaceInfo]?
        let wifiInfo: [String: InterfaceSampler.WifiInfo]?
    }

    override init() {
        super.init()
        wifiClient.delegate = self
        startListeningForWiFiEvents()
    }

    deinit {
        timer?.cancel()
    }

    func start(interval: Double) {
        let clamped = max(0.2, min(interval, 10.0))
        if currentInterval == clamped, timer != nil { return }
        currentInterval = clamped

        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        let leeway = DispatchTimeInterval.milliseconds(max(50, Int(clamped * 100)))
        timer.schedule(deadline: .now(), repeating: clamped, leeway: leeway)
        timer.setEventHandler { [weak self] in
            self?.refresh()
        }
        timer.resume()
        self.timer = timer
    }

    func setDetailMonitoringEnabled(_ enabled: Bool) {
        guard detailMonitoringEnabled != enabled else { return }
        detailMonitoringEnabled = enabled
        detailMonitoringGeneration &+= 1

        if enabled {
            forceDetailRefresh = true
            refresh()
        } else {
            forceDetailRefresh = false
            processSnapshot = [:]
            processSnapshotTime = nil
            topAppLastActiveTime.removeAll()
            if !topApps.isEmpty {
                topApps = []
            }
        }
    }

    private func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true

        let now = Date()
        let forcedDetailRefresh = forceDetailRefresh
        let refreshInterfaceInfo = cachedInterfaceInfo.isEmpty || shouldRefresh(lastInterfaceInfoRefresh, at: now, interval: Self.interfaceInfoRefreshInterval)
        let refreshWifiInfo = detailMonitoringEnabled && (
            forcedDetailRefresh ||
            _cachedWifiInfo.isEmpty ||
            shouldRefresh(lastWiFiDetailsRefresh, at: now, interval: Self.wifiDetailsRefreshInterval)
        )
        let shouldRefreshTopApps = detailMonitoringEnabled &&
            UserDefaults.standard.bool(forKey: "showTopApps") &&
            (forcedDetailRefresh || shouldRefresh(lastTopAppsRefresh, at: now, interval: Self.topAppsRefreshInterval))
        let shouldRefreshAddressDetails = detailMonitoringEnabled &&
            (forcedDetailRefresh || shouldRefresh(lastAddressDetailsRefresh, at: now, interval: Self.addressDetailsRefreshInterval))
        let shouldRefreshRouters = detailMonitoringEnabled &&
            (forcedDetailRefresh || shouldRefresh(lastRouterRefresh, at: now, interval: Self.routerRefreshInterval))
        let previousSamples = lastSample
        let previousUpdate = lastUpdate
        let cachedInterfaceInfo = self.cachedInterfaceInfo
        let cachedWifiInfo = self._cachedWifiInfo
        forceDetailRefresh = false

        refreshQueue.async { [weak self] in
            let result = Self.computeRefreshResult(
                now: now,
                previousSamples: previousSamples,
                previousUpdate: previousUpdate,
                cachedInterfaceInfo: cachedInterfaceInfo,
                cachedWifiInfo: cachedWifiInfo,
                refreshInterfaceInfo: refreshInterfaceInfo,
                refreshWifiInfo: refreshWifiInfo
            )

            DispatchQueue.main.async { [weak self] in
                self?.applyRefresh(
                    result: result,
                    now: now,
                    shouldRefreshTopApps: shouldRefreshTopApps,
                    forcedDetailRefresh: forcedDetailRefresh,
                    shouldRefreshAddressDetails: shouldRefreshAddressDetails,
                    shouldRefreshRouters: shouldRefreshRouters
                )
            }
        }
    }

    private nonisolated static func computeRefreshResult(
        now: Date,
        previousSamples: [String: InterfaceSample],
        previousUpdate: Date?,
        cachedInterfaceInfo: [String: InterfaceSampler.InterfaceInfo],
        cachedWifiInfo: [String: InterfaceSampler.WifiInfo],
        refreshInterfaceInfo: Bool,
        refreshWifiInfo: Bool
    ) -> RefreshResult {
        let samples = InterfaceSampler.fetchSamples()
        let infoMap = refreshInterfaceInfo ? InterfaceSampler.interfaceInfo() : cachedInterfaceInfo
        let wifiInfoMap = refreshWifiInfo ? InterfaceSampler.wifiInfo() : cachedWifiInfo

        var updatedAdapters: [AdapterStatus] = []
        var totalRxRate: Double = 0
        var totalTxRate: Double = 0
        let deltaTime = now.timeIntervalSince(previousUpdate ?? now)

        for sample in samples {
            let previous = previousSamples[sample.name]
            let rxRate = InterfaceSampler.rate(current: sample.rxBytes, previous: previous?.rxBytes, deltaTime: deltaTime)
            let txRate = InterfaceSampler.rate(current: sample.txBytes, previous: previous?.txBytes, deltaTime: deltaTime)

            let info = infoMap[sample.name]
            let type = info?.type ?? .other
            let displayName = info?.displayName ?? sample.name
            let isTunnelInterface = AdapterClassifier.isTunnelInterface(named: sample.name)
            let wifiInfo = wifiInfoMap[sample.name]
            let isUp = (sample.flags & UInt32(IFF_UP)) != 0
            let linkSpeed = type == .ethernet ? sample.baudrate : nil

            let adapter = AdapterStatus(
                id: sample.name,
                displayName: displayName,
                type: type,
                isTunnelInterface: isTunnelInterface,
                isUp: isUp,
                linkSpeedBps: linkSpeed,
                wifiMode: wifiInfo?.mode,
                wifiTxRateMbps: wifiInfo?.txRate,
                wifiSSID: wifiInfo?.ssid,
                wifiDetail: wifiInfo?.detail,
                rxBytes: sample.rxBytes,
                txBytes: sample.txBytes,
                rxRateBps: rxRate,
                txRateBps: txRate
            )
            updatedAdapters.append(adapter)
            totalRxRate += rxRate
            totalTxRate += txRate
        }

        updatedAdapters.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        return RefreshResult(
            adapters: updatedAdapters,
            totals: RateTotals(rxRateBps: totalRxRate, txRateBps: totalTxRate),
            samplesByName: Dictionary(uniqueKeysWithValues: samples.map { ($0.name, $0) }),
            interfaceInfo: refreshInterfaceInfo ? infoMap : nil,
            wifiInfo: refreshWifiInfo ? wifiInfoMap : nil
        )
    }

    private func applyRefresh(
        result: RefreshResult,
        now: Date,
        shouldRefreshTopApps: Bool,
        forcedDetailRefresh: Bool,
        shouldRefreshAddressDetails: Bool,
        shouldRefreshRouters: Bool
    ) {
        if let infoMap = result.interfaceInfo {
            cachedInterfaceInfo = infoMap
            lastInterfaceInfoRefresh = now
        }
        if let wifiInfoMap = result.wifiInfo {
            _cachedWifiInfo = wifiInfoMap
            lastWiFiDetailsRefresh = now
        }

        setIfChanged(\.adapters, to: result.adapters)
        setIfChanged(\.totals, to: result.totals)
        lastSample = result.samplesByName
        lastUpdate = now

        let updatedAdapters = result.adapters

        // Adapter grace period tracking
        let graceEnabled = UserDefaults.standard.bool(forKey: "adapterGracePeriodEnabled")
        let graceSeconds = UserDefaults.standard.double(forKey: "adapterGracePeriodSeconds")
        let currentAdapterIDs = Set(updatedAdapters.map(\.id))

        for adapter in updatedAdapters {
            let hasBandwidth = adapter.rxRateBps > 0 || adapter.txRateBps > 0
            if hasBandwidth {
                adapterLastActiveTime[adapter.id] = now
            } else if adapterLastActiveTime[adapter.id] == nil {
                // First time seeing this adapter — give it an initial grace window
                // so it doesn't vanish immediately on app start.
                adapterLastActiveTime[adapter.id] = now
            }
        }

        if graceEnabled {
            var deadlines: [String: Date] = [:]
            for adapter in updatedAdapters {
                let hasBandwidth = adapter.rxRateBps > 0 || adapter.txRateBps > 0
                if !hasBandwidth, let lastActive = adapterLastActiveTime[adapter.id] {
                    let deadline = lastActive.addingTimeInterval(graceSeconds)
                    if now < deadline {
                        deadlines[adapter.id] = deadline
                    }
                }
            }
            setIfChanged(\.adapterGraceDeadlines, to: deadlines)
        } else {
            if !adapterGraceDeadlines.isEmpty { adapterGraceDeadlines = [:] }
        }

        // Clean up tracking for adapters no longer returned by getifaddrs
        adapterLastActiveTime = adapterLastActiveTime.filter { currentAdapterIDs.contains($0.key) }

        // Top Apps: refresh on a slower cadence because `nettop` is significantly
        // heavier than `netstat`, but it captures Safari/WebKit traffic reliably.
        if shouldRefreshTopApps {
            lastTopAppsRefresh = now
            updateTopApps()
        }

        // Detail sections do not need background refresh while the popover is closed.
        if shouldRefreshAddressDetails {
            lastAddressDetailsRefresh = now
            updateIPsIfNeeded(force: forcedDetailRefresh)
        }
        if shouldRefreshRouters {
            lastRouterRefresh = now
            updateFritzBox()
            updateUniFi()
            updateOpenWRT()
        }

        let needsImmediateFollowUp = detailMonitoringEnabled && forceDetailRefresh
        refreshInFlight = false
        if needsImmediateFollowUp {
            refresh()
        }
    }

    private func setIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<NetworkMonitor, Value>,
        to newValue: Value
    ) {
        if self[keyPath: keyPath] != newValue {
            self[keyPath: keyPath] = newValue
        }
    }

    private func shouldRefresh(_ lastRefresh: Date?, at now: Date, interval: TimeInterval) -> Bool {
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= interval
    }

    // MARK: - Top Apps

    private func updateTopApps() {
        guard UserDefaults.standard.bool(forKey: "showTopApps") else {
            if !topApps.isEmpty { topApps = [] }
            return
        }
        guard !topAppsTaskInFlight else { return }
        topAppsTaskInFlight = true

        let previousSnapshot = processSnapshot
        let previousTime = processSnapshotTime
        let generation = detailMonitoringGeneration

        Task { [weak self] in
            let sampleTime = Date()
            let snapshot = await Task.detached(priority: .utility) {
                ProcessNetworkSampler.sampleConnections()
            }.value

            guard let self else { return }
            self.topAppsTaskInFlight = false
            guard self.detailMonitoringEnabled, self.detailMonitoringGeneration == generation else { return }

            if let prevTime = previousTime, !previousSnapshot.isEmpty {
                let elapsed = sampleTime.timeIntervalSince(prevTime)
                if elapsed >= 0.1 {
                    let hiddenApps = Set(UserDefaults.standard.stringArray(forKey: "hiddenApps") ?? [])
                    let now = Date()

                    // Get all active apps (unlimited) to track recently seen names
                    let allActive = ProcessNetworkSampler.rates(
                        from: ProcessNetworkSampler.appDeltas(current: snapshot, previous: previousSnapshot),
                        elapsed: elapsed,
                        limit: Int.max
                    )
                    for app in allActive {
                        self.allAppLastSeen[app.name] = now
                    }
                    // Expire entries older than 60 seconds and publish sorted list
                    self.allAppLastSeen = self.allAppLastSeen.filter { now.timeIntervalSince($0.value) < 60 }
                    self.setIfChanged(\.recentAppNames, to: self.allAppLastSeen.keys.sorted())

                    // Top 5 visible apps (filter out hidden)
                    var apps = Array(allActive.filter { !hiddenApps.contains($0.name) }.prefix(5))

                    let topAppsGraceEnabled = UserDefaults.standard.bool(forKey: "topAppsGracePeriodEnabled")
                    let topAppsGraceSeconds = UserDefaults.standard.double(forKey: "topAppsGracePeriodSeconds")

                    // Update last-active tracking for currently active apps
                    let activeNames = Set(apps.map(\.name))
                    for app in apps {
                        self.topAppLastActiveTime[app.name] = (lastSeen: now, rxRate: app.rxRateBps, txRate: app.txRateBps)
                    }

                    if topAppsGraceEnabled {
                        // Re-insert recently-active apps that are no longer active
                        for (name, entry) in self.topAppLastActiveTime {
                            if activeNames.contains(name) { continue }
                            if hiddenApps.contains(name) { continue }
                            let deadline = entry.lastSeen.addingTimeInterval(topAppsGraceSeconds)
                            if now < deadline {
                                apps.append(AppTraffic(id: name, name: name, rxRateBps: 0, txRateBps: 0))
                            }
                        }
                        // Sort: active apps first by throughput, then grace apps by name
                        apps.sort {
                            let aTotal = $0.rxRateBps + $0.txRateBps
                            let bTotal = $1.rxRateBps + $1.txRateBps
                            if aTotal > 0 && bTotal == 0 { return true }
                            if aTotal == 0 && bTotal > 0 { return false }
                            if aTotal > 0 && bTotal > 0 { return aTotal > bTotal }
                            return $0.name < $1.name
                        }
                        apps = Array(apps.prefix(5))
                        // Clean up expired entries
                        self.topAppLastActiveTime = self.topAppLastActiveTime.filter { now < $0.value.lastSeen.addingTimeInterval(topAppsGraceSeconds) }
                    } else {
                        self.topAppLastActiveTime.removeAll()
                    }

                    self.setIfChanged(\.topApps, to: apps)
                }
            }

            self.processSnapshot = snapshot
            self.processSnapshotTime = sampleTime
        }
    }

    // MARK: - IP Addresses

    private func updateIPsIfNeeded(force: Bool) {
        setIfChanged(\.internalIP, to: InterfaceSampler.primaryInternalIP())
        setIfChanged(\.gatewayIP, to: InterfaceSampler.defaultGatewayIP(store: dynamicStore))
        let now = Date()

        // DNS check spawns a process; keep it on its own slower cadence.
        if UserDefaults.standard.bool(forKey: "showDNSSwitcher"),
           (force || shouldRefresh(lastDNSRefresh, at: now, interval: Self.dnsRefreshInterval)) {
            updateCurrentDNS()
            lastDNSRefresh = now
        }
        let currentIPv6 = UserDefaults.standard.bool(forKey: "externalIPv6")
        let settingChanged = lastExternalIPv6Setting != nil && lastExternalIPv6Setting != currentIPv6
        if !force,
           !settingChanged,
           let lastExternalIPUpdate,
           now.timeIntervalSince(lastExternalIPUpdate) < Self.externalIPRefreshInterval {
            return
        }
        guard !externalIPInFlight else { return }
        lastExternalIPv6Setting = currentIPv6

        externalIPInFlight = true
        Task { [weak self] in
            let result = await Self.fetchExternalIP()
            guard let self else { return }
            self.setIfChanged(\.externalIP, to: result?.ip ?? "—")
            self.setIfChanged(\.externalIPCountryCode, to: result?.countryCode ?? "")
            self.lastExternalIPUpdate = Date()
            self.externalIPInFlight = false
        }
    }

    private static func fetchExternalIP() async -> (ip: String, countryCode: String)? {
        let useIPv6 = UserDefaults.standard.bool(forKey: "externalIPv6")
        let ipifyURL = useIPv6
            ? "https://api64.ipify.org?format=json"
            : "https://api.ipify.org?format=json"

        // Get the IP address from ipify (IPv4 or IPv6 based on preference)
        var ip: String?
        if let url = URL(string: ipifyURL) {
            let request = URLRequest(url: url, timeoutInterval: 8)
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                ip = json["ip"] as? String
            }
        }
        guard let ip else { return nil }

        // Only fetch country code when the connection flow view is active (needs flag emoji)
        let needsCountry = UserDefaults.standard.string(forKey: "connectionStatusMode") == "flow"
        if needsCountry, let url = URL(string: "https://ipwho.is/\(ip)") {
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.setValue("NetFluss/1.0", forHTTPHeaderField: "User-Agent")
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let country = json["country_code"] as? String {
                return (ip: ip, countryCode: country)
            }
        }
        return (ip: ip, countryCode: "")
    }

    // MARK: - DNS

    private func updateCurrentDNS() {
        let service = Self.primaryNetworkService()
        guard !service.isEmpty else { return }
        let output = Self.runSyncOutput("/usr/sbin/networksetup", ["-getdnsservers", service])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let servers: [String]
        if trimmed.contains("aren't any DNS") || trimmed.isEmpty {
            servers = []
        } else {
            servers = trimmed.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        setIfChanged(\.currentDNSServers, to: servers)
        setIfChanged(\.activeDNSPresetID, to: matchPreset(servers: servers))
    }

    private func startListeningForWiFiEvents() {
        do {
            try wifiClient.startMonitoringEvent(with: .ssidDidChange)
        } catch {
            // Best-effort optimization only; periodic refresh remains as fallback.
        }
    }

    private func stopListeningForWiFiEvents() {
        do {
            try wifiClient.stopMonitoringEvent(with: .ssidDidChange)
        } catch {
            // Ignore teardown failures on exit.
        }
    }

    private func matchPreset(servers: [String]) -> String? {
        let allPresets = Self.allDNSPresets()
        for preset in allPresets {
            if preset.servers.isEmpty && servers.isEmpty { return preset.id }
            if preset.servers == servers { return preset.id }
        }
        return nil
    }

    static func allDNSPresets() -> [DNSPreset] {
        var presets = DNSPreset.builtIn
        if let data = UserDefaults.standard.data(forKey: "customDNSPresets"),
           let custom = try? JSONDecoder().decode([DNSPreset].self, from: data) {
            presets += custom
        }
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenDNSPresets") ?? [])
        presets.removeAll { hidden.contains($0.id) }
        let order = UserDefaults.standard.stringArray(forKey: "dnsPresetOrder") ?? []
        if !order.isEmpty {
            let orderIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            presets.sort {
                let ai = orderIndex[$0.id] ?? Int.max
                let bi = orderIndex[$1.id] ?? Int.max
                return ai < bi
            }
        }
        return presets
    }

    func applyDNS(preset: DNSPreset) {
        guard !dnsChanging else { return }
        // Validate server addresses: only allow IP-safe characters
        let validChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:[]")
        for s in preset.servers {
            guard s.unicodeScalars.allSatisfy({ validChars.contains($0) }) else {
                dnsError = "Invalid DNS server address."
                return
            }
        }
        dnsChanging = true
        dnsError = nil

        let servers = preset.servers
        Task.detached(priority: .userInitiated) { [weak self] in
            let service = Self.primaryNetworkService()
            guard !service.isEmpty else {
                _ = await MainActor.run { [weak self] in
                    self?.dnsChanging = false
                    self?.dnsError = "No active network service found."
                }
                return
            }

            let command: String
            if servers.isEmpty {
                command = "/usr/sbin/networksetup -setdnsservers '\(service)' empty"
            } else {
                let joined = servers.joined(separator: " ")
                command = "/usr/sbin/networksetup -setdnsservers '\(service)' \(joined)"
            }
            let result = await PrivilegedHelperManager.shared.setDNS(serviceName: service, servers: servers) ??
                Self.executeWithAuth(command: command)

            _ = await MainActor.run { [weak self] in
                self?.dnsChanging = false
                self?.dnsError = result.success ? nil : Self.describePrivilegedCommandFailure(result)
                self?.updateCurrentDNS()
            }
        }
    }

    private nonisolated static func primaryNetworkService(store: SCDynamicStore? = nil) -> String {
        let s = store ?? SCDynamicStoreCreate(nil, "NetFluss.DNS" as CFString, nil, nil)
        let key = SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv4)
        guard let dict = SCDynamicStoreCopyValue(s, key) as? [String: Any] else { return "" }

        if let primaryServiceID = dict["PrimaryService"] as? String,
           let serviceName = networkServiceName(for: primaryServiceID),
           !serviceName.isEmpty {
            return serviceName
        }

        if let primaryInterface = dict["PrimaryInterface"] as? String {
            return hardwarePortName(for: primaryInterface)
        }

        return ""
    }

    // MARK: - Reconnect

    func reconnect(adapter: AdapterStatus) {
        guard adapter.type == .wifi || adapter.type == .ethernet else { return }
        let bsdName = adapter.id
        // BSD names from getifaddrs are kernel-provided (e.g. "en0"), but validate
        // before interpolating into a shell command as a defense-in-depth measure.
        guard bsdName.allSatisfy({ $0.isLetter || $0.isNumber }) else { return }
        reconnectingAdapters.insert(bsdName)

        Task.detached(priority: .userInitiated) { [weak self, bsdName, type = adapter.type] in
            switch type {
            case .wifi:
                let port = Self.hardwarePortName(for: bsdName)
                Self.runSync("/usr/sbin/networksetup", ["-setairportpower", port, "off"])
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                Self.runSync("/usr/sbin/networksetup", ["-setairportpower", port, "on"])
            case .ethernet:
                _ = await PrivilegedHelperManager.shared.reconnectEthernet(interfaceName: bsdName) ??
                    Self.executeWithAuth(command: "ifconfig \(bsdName) down && sleep 1 && ifconfig \(bsdName) up")
            case .other:
                break
            }
            _ = await MainActor.run { [weak self] in self?.reconnectingAdapters.remove(bsdName) }
        }
    }

    /// Returns the hardware port display name (e.g. "Wi-Fi") for a BSD interface.
    /// Falls back to the BSD name if not found.
    private nonisolated static func hardwarePortName(for bsdName: String) -> String {
        let output = runSyncOutput("/usr/sbin/networksetup", ["-listallhardwareports"])
        var currentPort = ""
        for line in output.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Hardware Port:") {
                currentPort = String(t.dropFirst("Hardware Port:".count)).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("Device:") {
                let dev = String(t.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
                if dev == bsdName { return currentPort }
            }
        }
        return bsdName
    }

    private nonisolated static func networkServiceName(for serviceID: String) -> String? {
        guard let preferences = SCPreferencesCreate(nil, "NetFluss.DNS" as CFString, nil),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            return nil
        }

        for service in services {
            guard let currentServiceID = SCNetworkServiceGetServiceID(service) as String?,
                  currentServiceID == serviceID else {
                continue
            }

            if let name = SCNetworkServiceGetName(service) as String?,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
        }

        return nil
    }

    /// Legacy fallback for raw dev runs where the privileged helper is not bundled.
    private nonisolated static func executeWithAuth(command: String) -> CommandResult {
        let prompt = "Netfluss needs administrator permission to modify network settings."
        let privilegedResult = command.withCString { commandPointer in
            prompt.withCString { promptPointer in
                NetflussExecutePrivilegedCommand(commandPointer, promptPointer)
            }
        }

        let output: String
        if let outputPointer = privilegedResult.output {
            output = String(cString: outputPointer)
        } else {
            output = ""
        }
        NetflussFreePrivilegedCommandResult(privilegedResult)

        if privilegedResult.authorizationStatus == Int32(errAuthorizationSuccess) {
            return CommandResult(
                terminationStatus: privilegedResult.commandStatus,
                stdout: privilegedResult.commandStatus == 0 ? output : "",
                stderr: privilegedResult.commandStatus == 0 ? "" : output
            )
        }

        if shouldFallbackToAppleScript(for: privilegedResult.authorizationStatus) {
            let escapedCommand = command
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = "do shell script \"\(escapedCommand)\" with administrator privileges"
            return runSyncResult("/usr/bin/osascript", ["-e", script])
        }

        return CommandResult(
            terminationStatus: privilegedResult.authorizationStatus,
            stdout: "",
            stderr: output
        )
    }

    private nonisolated static func runSync(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }

    private nonisolated static func runSyncResult(_ path: String, _ args: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        guard (try? process.run()) != nil else {
            return CommandResult(
                terminationStatus: -1,
                stdout: "",
                stderr: "Failed to launch \(path)."
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            terminationStatus: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private nonisolated static func describePrivilegedCommandFailure(_ result: CommandResult) -> String {
        switch result.terminationStatus {
        case PrivilegedCommandStatus.helperApprovalRequired:
            return "Approve the Netfluss helper in System Settings, then try again."
        case Int32(errAuthorizationCanceled):
            return "DNS change was canceled."
        case Int32(errAuthorizationDenied):
            return "Administrator permission was denied."
        case Int32(errAuthorizationInteractionNotAllowed):
            return "Administrator authentication is not available right now."
        case Int32(errAuthorizationToolExecuteFailure):
            return "The privileged helper could not be started."
        default:
            break
        }

        let combined = [result.stderr, result.stdout]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if combined.localizedCaseInsensitiveContains("User canceled") {
            return "DNS change was canceled."
        }
        if combined.localizedCaseInsensitiveContains("privilege") ||
            combined.localizedCaseInsensitiveContains("not authorized") {
            return "Administrator permission was not granted."
        }
        if combined.localizedCaseInsensitiveContains("not a recognized network service") {
            return "The active network service could not be identified."
        }

        if let firstLine = combined
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return firstLine
        }

        return "DNS change failed."
    }

    private nonisolated static func shouldFallbackToAppleScript(for authorizationStatus: Int32) -> Bool {
        switch authorizationStatus {
        case Int32(errAuthorizationCanceled), Int32(errAuthorizationDenied), Int32(errAuthorizationInteractionNotAllowed):
            return false
        default:
            return true
        }
    }

    // MARK: - Fritz!Box

    private func updateFritzBox() {
        guard UserDefaults.standard.bool(forKey: "fritzBoxEnabled") else {
            if fritzBox != nil { fritzBox = nil }
            if fritzBoxError != nil { fritzBoxError = nil }
            fritzBoxLinkFetched = false
            fritzBoxFailureCount = 0
            return
        }
        guard !fritzBoxInFlight else { return }
        fritzBoxInFlight = true

        let customHost = UserDefaults.standard.string(forKey: "fritzBoxHost") ?? ""
        let host = customHost.isEmpty ? gatewayIP : customHost
        let needsLink = !fritzBoxLinkFetched
        let usesAutoHost = customHost.isEmpty

        Task { [weak self] in
            guard let self else { return }
            if needsLink {
                do {
                    let link = try await FritzBoxMonitor.fetchLinkProperties(host: host)
                    if self.fritzBoxMaxDown != link.maxDown { self.fritzBoxMaxDown = link.maxDown }
                    if self.fritzBoxMaxUp != link.maxUp { self.fritzBoxMaxUp = link.maxUp }
                    self.fritzBoxLinkFetched = true
                } catch {
                    self.fritzBoxLinkFetched = false
                }
            }

            do {
                let bandwidth = try await FritzBoxMonitor.fetchBandwidth(host: host)
                self.setIfChanged(\.fritzBox, to: bandwidth)
                self.fritzBoxFailureCount = 0
                self.setIfChanged(\.fritzBoxError, to: nil)
            } catch {
                self.fritzBoxFailureCount += 1

                let errorMessage = Self.describeFritzBoxError(
                    error,
                    host: host,
                    usesAutoHost: usesAutoHost
                )
                if self.fritzBox == nil || self.fritzBoxFailureCount >= Self.fritzBoxFailureThreshold {
                    self.setIfChanged(\.fritzBoxError, to: errorMessage)
                }
            }
            self.fritzBoxInFlight = false
        }
    }

    // MARK: - UniFi

    private func updateUniFi() {
        guard UserDefaults.standard.bool(forKey: "unifiEnabled") else {
            if unifi != nil { unifi = nil }
            if unifiError != nil { unifiError = nil }
            return
        }
        guard !unifiInFlight else { return }
        unifiInFlight = true

        let customHost = UserDefaults.standard.string(forKey: "unifiHost") ?? ""
        let host = customHost.isEmpty ? gatewayIP : customHost

        Task { [weak self] in
            guard let self else { return }
            do {
                guard let creds = UniFiMonitor.loadCredentials(host: host) else {
                    let msg = "No credentials configured"
                    self.setIfChanged(\.unifiError, to: msg)
                    self.setIfChanged(\.unifi, to: nil)
                    self.unifiInFlight = false
                    return
                }
                let bandwidth = try await UniFiMonitor.fetchBandwidth(
                    host: host, username: creds.username, password: creds.password
                )
                self.setIfChanged(\.unifi, to: bandwidth)
                self.setIfChanged(\.unifiError, to: nil)
            } catch {
                self.setIfChanged(\.unifi, to: nil)
                let msg = "Cannot reach UniFi gateway"
                self.setIfChanged(\.unifiError, to: msg)
            }
            self.unifiInFlight = false
        }
    }

    // MARK: - OpenWRT

    private func updateOpenWRT() {
        guard UserDefaults.standard.bool(forKey: "openWRTEnabled") else {
            if openWRT != nil { openWRT = nil }
            if openWRTError != nil { openWRTError = nil }
            openWRTLastSample = nil
            return
        }
        guard !openWRTInFlight else { return }
        openWRTInFlight = true

        let customHost = UserDefaults.standard.string(forKey: "openWRTHost") ?? ""
        let host = customHost.isEmpty ? gatewayIP : customHost

        Task { [weak self] in
            guard let self else { return }
            do {
                guard let creds = OpenWRTMonitor.loadCredentials(host: host) else {
                    let msg = "No credentials configured"
                    self.setIfChanged(\.openWRTError, to: msg)
                    self.setIfChanged(\.openWRT, to: nil)
                    self.openWRTInFlight = false
                    return
                }
                let sample = try await OpenWRTMonitor.fetchSample(
                    host: host, username: creds.username, password: creds.password
                )
                // Compute rates from previous sample
                if let prev = self.openWRTLastSample {
                    let dt = sample.timestamp.timeIntervalSince(prev.timestamp)
                    if dt > 0 {
                        let rxRate = Double(sample.rxBytes &- prev.rxBytes) / dt
                        let txRate = Double(sample.txBytes &- prev.txBytes) / dt
                        self.setIfChanged(\.openWRT, to: OpenWRTBandwidth(
                            rxRateBps: rxRate,
                            txRateBps: txRate,
                            linkSpeedMbps: sample.linkSpeedMbps
                        ))
                    }
                }
                self.openWRTLastSample = sample
                self.setIfChanged(\.openWRTError, to: nil)
            } catch {
                self.setIfChanged(\.openWRT, to: nil)
                let msg = "Cannot reach OpenWRT router"
                self.setIfChanged(\.openWRTError, to: msg)
            }
            self.openWRTInFlight = false
        }
    }

    private nonisolated static func runSyncOutput(_ path: String, _ args: [String]) -> String {
        runSyncResult(path, args).stdout
    }

    private nonisolated static func describeFritzBoxError(
        _ error: Error,
        host: String,
        usesAutoHost: Bool
    ) -> String {
        if let fritzBoxError = error as? FritzBoxError {
            switch fritzBoxError {
            case .invalidHost:
                return usesAutoHost
                    ? "No Fritz!Box gateway detected. Set the router address manually."
                    : "Enter a valid Fritz!Box address."
            case .invalidURL:
                return "Enter a valid Fritz!Box address."
            case .requestFailed(let statusCode):
                if let statusCode {
                    return "Fritz!Box TR-064 request failed (HTTP \(statusCode))."
                }
                return "Fritz!Box TR-064 request failed."
            case .transport(let description):
                if usesAutoHost {
                    return "Cannot reach Fritz!Box at \(host). Set the router address manually if auto detection picked the wrong gateway."
                }
                if !description.isEmpty {
                    return description
                }
                return "Cannot reach Fritz!Box at \(host)."
            case .parseError:
                return "Fritz!Box returned an unexpected TR-064 response."
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "Fritz!Box did not respond in time."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet:
                if usesAutoHost {
                    return "Cannot reach Fritz!Box at \(host). Set the router address manually if auto detection picked the wrong gateway."
                }
                return "Cannot reach Fritz!Box at \(host)."
            default:
                break
            }
        }

        let message = (error as NSError).localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            return message
        }
        return "Cannot reach Fritz!Box."
    }
}

struct CommandResult: Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String

    var success: Bool {
        terminationStatus == 0
    }
}

@MainActor
extension NetworkMonitor: @preconcurrency CWEventDelegate {
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        lastWiFiDetailsRefresh = nil
        _cachedWifiInfo = [:]
        forceDetailRefresh = true
        if detailMonitoringEnabled && !refreshInFlight {
            refresh()
        }
    }
}

// MARK: - Process Network Sampler

struct ProcessConnectionSnapshot: Equatable, Sendable {
    let id: String
    let name: String
    let source: ProcessTrafficSource
    let downloadBytes: UInt64
    let uploadBytes: UInt64
}

enum ProcessTrafficSource: Hashable, Sendable {
    case processSummary
    case internetSocket
    case networkSource

    var countsInitialObservationAsDelta: Bool {
        switch self {
        case .processSummary:
            return false
        case .internetSocket, .networkSource:
            return true
        }
    }
}

enum ProcessNetworkSampler {

    // PID→name cache: avoids repeated proc_pidpath + filesystem lookups.
    // Cleared every ~10 samples (caller resets via clearNameCache()).
    private static var pidNameCache: [pid_t: String] = [:]
    private static var pidNameCacheAge: UInt64 = 0
    private static let sampleCondition = NSCondition()
    private static let snapshotReuseInterval: TimeInterval = 2
    private static var cachedSnapshot: [String: ProcessConnectionSnapshot] = [:]
    private static var cachedSnapshotTime: Date?
    private static var sampleInFlight = false

    static func clearNameCacheIfNeeded() {
        pidNameCacheAge &+= 1
        if pidNameCacheAge % 10 == 0 {
            pidNameCache.removeAll(keepingCapacity: true)
        }
    }

    /// Snapshot: cumulative bytes per process at a point in time.
    /// Primary source is `nettop -P`, which exposes per-process byte totals and
    /// captures Safari/WebKit traffic more reliably than per-socket `netstat`.
    /// Falls back to `netstat -n -b -v` if `nettop` is unavailable.
    static func sampleConnections() -> [String: ProcessConnectionSnapshot] {
        clearNameCacheIfNeeded()
        while true {
            sampleCondition.lock()
            let now = Date()
            if let cachedSnapshotTime,
               now.timeIntervalSince(cachedSnapshotTime) < snapshotReuseInterval {
                let snapshot = cachedSnapshot
                sampleCondition.unlock()
                return snapshot
            }
            if !sampleInFlight {
                sampleInFlight = true
                sampleCondition.unlock()
                break
            }
            sampleCondition.wait()
            sampleCondition.unlock()
        }

        var snapshot = sampleConnectionsFromNettop()
        if snapshot.isEmpty {
            snapshot = sampleConnectionsFromNetstat()
        }

        sampleCondition.lock()
        cachedSnapshot = snapshot
        cachedSnapshotTime = Date()
        sampleInFlight = false
        sampleCondition.broadcast()
        sampleCondition.unlock()

        return snapshot
    }

    /// Fallback snapshot: cumulative inet bytes per live socket at a point in time.
    /// Uses `netstat -n -b -v` which exposes per-connection rxbytes/txbytes with process:pid.
    private static func sampleConnectionsFromNetstat() -> [String: ProcessConnectionSnapshot] {
        let output = runNetstat()
        var connections: [String: ProcessConnectionSnapshot] = [:]

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 8 else { continue }
            let proto = String(parts[0])
            let isTCP = proto.hasPrefix("tcp")
            let isUDP = proto.hasPrefix("udp")
            let isNetworkSource = proto == "kctl" && parts.last == "com.apple.netsrc"
            guard isTCP || isUDP || isNetworkSource else { continue }

            // TCP:  proto recv-q send-q local foreign STATE rxbytes txbytes ...
            // UDP:  proto recv-q send-q local foreign rxbytes txbytes ...
            // KCTL: proto recv-q send-q rxbytes txbytes rhiwat shiwat process:pid ... unit id service
            let rxIndex: Int
            let txIndex: Int
            let source: ProcessTrafficSource
            if isTCP {
                rxIndex = 6
                txIndex = 7
                source = .internetSocket
            } else if isUDP {
                rxIndex = 5
                txIndex = 6
                source = .internetSocket
            } else {
                rxIndex = 3
                txIndex = 4
                source = .networkSource
            }
            guard txIndex < parts.count,
                  let rx = UInt64(parts[rxIndex]),
                  let tx = UInt64(parts[txIndex]),
                  rx > 0 || tx > 0 else { continue }

            // Locate the PID. Two formats exist across macOS versions:
            //   macOS 26+: "name:pid" token appended to the line
            //   macOS 15:  dedicated numeric column at rxIndex + 4
            //              (proto recv-q send-q local foreign [state] rx tx rhiwat shiwat pid …)
            // IPv6 address tokens (e.g. "2a02:810a:912:d5.57207") are excluded from the
            // token search because their last colon-suffix contains a dot, so Int32 parsing fails.
            var pid: pid_t? = nil
            if let pidToken = parts.first(where: { token in
                token.contains(":") &&
                token.split(separator: ":", omittingEmptySubsequences: true)
                     .last.flatMap({ Int32($0) }) != nil
            }) {
                pid = pidToken.split(separator: ":").last.flatMap({ Int32($0) })
            } else {
                let pidIdx = rxIndex + 4
                if pidIdx < parts.count { pid = Int32(parts[pidIdx]) }
            }
            guard let pid, pid > 0 else { continue }

            let name: String
            if let cached = pidNameCache[pid] {
                name = cached
            } else {
                let resolved = processName(for: pid) ?? "PID \(pid)"
                pidNameCache[pid] = resolved
                name = resolved
            }

            let connectionID: String
            if isNetworkSource, parts.count >= 19 {
                connectionID = [
                    proto,
                    String(pid),
                    String(parts[16]),
                    String(parts[17]),
                    String(parts[18])
                ].joined(separator: "|")
            } else {
                connectionID = [
                    proto,
                    String(parts[3]),
                    String(parts[4]),
                    String(pid)
                ].joined(separator: "|")
            }

            connections[connectionID] = ProcessConnectionSnapshot(
                id: connectionID,
                name: name,
                source: source,
                downloadBytes: rx,
                uploadBytes: tx
            )
        }
        return connections
    }

    private static func sampleConnectionsFromNettop() -> [String: ProcessConnectionSnapshot] {
        let output = runNettop()
        var connections: [String: ProcessConnectionSnapshot] = [:]

        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }

            let rawIdentifier = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawIdentifier.isEmpty else { continue } // CSV header row
            guard let separatorIndex = rawIdentifier.lastIndex(of: ".") else { continue }

            let pidSuffix = rawIdentifier[rawIdentifier.index(after: separatorIndex)...]
            guard let pid = Int32(pidSuffix), pid > 0 else { continue }

            let rawDownload = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawUpload = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let downloadBytes = UInt64(rawDownload),
                  let uploadBytes = UInt64(rawUpload),
                  downloadBytes > 0 || uploadBytes > 0 else { continue }

            let name: String
            if let cached = pidNameCache[pid] {
                name = cached
            } else {
                let resolved = processName(for: pid) ?? "PID \(pid)"
                pidNameCache[pid] = resolved
                name = resolved
            }

            let id = String(pid)
            connections[id] = ProcessConnectionSnapshot(
                id: id,
                name: name,
                source: .processSummary,
                downloadBytes: downloadBytes,
                uploadBytes: uploadBytes
            )
        }

        return connections
    }

    /// Aggregate per-connection deltas back to app names.
    static func appDeltas(
        current: [String: ProcessConnectionSnapshot],
        previous: [String: ProcessConnectionSnapshot]
    ) -> [String: (rx: UInt64, tx: UInt64)] {
        var totals: [String: [ProcessTrafficSource: (rx: UInt64, tx: UInt64)]] = [:]

        for connection in current.values {
            let previousConnection = previous[connection.id]
            let rxDelta: UInt64
            let txDelta: UInt64
            if let previousConnection {
                rxDelta = delta(current: connection.downloadBytes, previous: previousConnection.downloadBytes)
                txDelta = delta(current: connection.uploadBytes, previous: previousConnection.uploadBytes)
            } else if connection.source.countsInitialObservationAsDelta {
                rxDelta = connection.downloadBytes
                txDelta = connection.uploadBytes
            } else {
                continue
            }
            guard rxDelta > 0 || txDelta > 0 else { continue }

            var sourceTotals = totals[connection.name] ?? [:]
            let existing = sourceTotals[connection.source] ?? (rx: 0, tx: 0)
            sourceTotals[connection.source] = (
                rx: existing.rx + rxDelta,
                tx: existing.tx + txDelta
            )
            totals[connection.name] = sourceTotals
        }

        var selectedTotals: [String: (rx: UInt64, tx: UInt64)] = [:]
        selectedTotals.reserveCapacity(totals.count)

        for (name, sourceTotals) in totals {
            if let processSummaryTotals = sourceTotals[.processSummary] {
                selectedTotals[name] = processSummaryTotals
                continue
            }
            let socketTotals = sourceTotals[.internetSocket] ?? (rx: 0, tx: 0)
            let networkSourceTotals = sourceTotals[.networkSource] ?? (rx: 0, tx: 0)
            let socketBytes = socketTotals.rx + socketTotals.tx
            let networkSourceBytes = networkSourceTotals.rx + networkSourceTotals.tx
            selectedTotals[name] = networkSourceBytes > socketBytes ? networkSourceTotals : socketTotals
        }

        return selectedTotals
    }

    /// Convert app delta totals into per-second rates, sorted by total traffic.
    static func rates(
        from deltas: [String: (rx: UInt64, tx: UInt64)],
        elapsed: Double,
        limit: Int
    ) -> [AppTraffic] {
        var apps: [AppTraffic] = []

        for (name, deltaTotals) in deltas {
            let rxRate = Double(deltaTotals.rx) / elapsed
            let txRate = Double(deltaTotals.tx) / elapsed
            guard rxRate > 0 || txRate > 0 else { continue }
            apps.append(AppTraffic(id: name, name: name, rxRateBps: rxRate, txRateBps: txRate))
        }

        return apps
            .sorted { ($0.rxRateBps + $0.txRateBps) > ($1.rxRateBps + $1.txRateBps) }
            .prefix(limit)
            .map { $0 }
    }

    private static func delta(current: UInt64, previous: UInt64?) -> UInt64 {
        guard let previous else { return current }
        return current >= previous ? current - previous : current
    }

    // MARK: - Helpers

    private static func runNetstat() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-n", "-b", "-v"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        // Read before waitUntilExit to avoid pipe-buffer deadlock (~185 KB output)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func runNettop() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-x", "-L", "1", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Best-effort process name: tries full path (for clean app names), falls back to proc_name.
    /// Uses a shared buffer to avoid per-call heap allocations.
    private static var pathBuffer = [CChar](repeating: 0, count: Int(PATH_MAX) * 4)

    private static func processName(for pid: pid_t) -> String? {
        let pathLen = pathBuffer.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        if pathLen > 0 {
            let path = pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if let appBundleName = enclosingAppBundleName(from: path) {
                return normalizedProcessName(appBundleName, path: path)
            }
            if let appName = runningApplicationName(for: pid) {
                return normalizedProcessName(appName, path: path)
            }
            let url = URL(fileURLWithPath: path)
            let name = url.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return normalizedProcessName(name, path: path) }
        }

        if let appName = runningApplicationName(for: pid) {
            return normalizedProcessName(appName, path: nil)
        }

        var nameBuf = [CChar](repeating: 0, count: 1024)
        let nameLen = nameBuf.withUnsafeMutableBytes {
            proc_name(pid, $0.baseAddress, UInt32($0.count))
        }
        guard nameLen > 0 else { return nil }
        return nameBuf.withUnsafeBufferPointer { normalizedProcessName(String(cString: $0.baseAddress!), path: nil) }
    }

    private static func enclosingAppBundleName(from path: String) -> String? {
        // Strip .app bundle path: ".../Safari.app/Contents/MacOS/Safari" → "Safari"
        guard let appRange = path.range(of: ".app/", options: .caseInsensitive) else { return nil }
        let appPath = String(path[path.startIndex..<appRange.lowerBound])
        if let lastSlash = appPath.lastIndex(of: "/") {
            let name = String(appPath[appPath.index(after: lastSlash)...])
            if !name.isEmpty { return name }
        }
        let name = appPath.isEmpty ? "" : (appPath as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func runningApplicationName(for pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              var name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else {
            return nil
        }

        for suffix in [" Networking", " Web Content", " GPU"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }

        return name.isEmpty ? nil : name
    }

    private static func normalizedProcessName(_ rawName: String, path: String?) -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return rawName }

        if name == "Safari" || name.hasPrefix("Safari ") || name.hasPrefix("com.apple.Safari.") {
            return "Safari"
        }

        if let path,
           path.contains("/SafariSafeBrowsing.framework/") || path.contains("/SafariShared.framework/") {
            return "Safari"
        }

        return name
    }
}

// MARK: - Interface Sampler

enum InterfaceSampler {
    static func fetchSamples() -> [InterfaceSample] {
        let routeSamples = fetchSamplesViaRoutingTable()
        if !routeSamples.isEmpty {
            return routeSamples
        }

        return fetchSamplesViaGetifaddrs()
    }

    private static func fetchSamplesViaRoutingTable() -> [InterfaceSample] {
        // getifaddrs(AF_LINK) only exposes `if_data`, whose byte counters are
        // 32-bit on macOS. Fast LAN transfers can wrap those counters and make
        // receive/upload rates collapse to zero. NET_RT_IFLIST2 exposes
        // `if_msghdr2.ifm_data` with 64-bit interface counters.
        var mib = [
            Int32(CTL_NET),
            Int32(PF_ROUTE),
            0,
            0,
            Int32(NET_RT_IFLIST2),
            0
        ]

        var length: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0,
              length > 0 else {
            return []
        }

        var buffer = [UInt8](repeating: 0, count: length)
        let sysctlResult = buffer.withUnsafeMutableBytes { rawBuffer -> Int32 in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return sysctl(&mib, u_int(mib.count), baseAddress, &length, nil, 0)
        }
        guard sysctlResult == 0 else { return [] }

        var samples: [InterfaceSample] = []
        samples.reserveCapacity(16)

        buffer.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }

            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let messageHeader = baseAddress
                    .advanced(by: offset)
                    .assumingMemoryBound(to: if_msghdr.self)
                    .pointee

                let messageLength = Int(messageHeader.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                defer { offset += messageLength }

                guard messageHeader.ifm_type == UInt8(RTM_IFINFO2),
                      messageLength >= MemoryLayout<if_msghdr2>.size else {
                    continue
                }

                let interfaceMessage = baseAddress
                    .advanced(by: offset)
                    .assumingMemoryBound(to: if_msghdr2.self)
                    .pointee

                guard let name = interfaceName(for: interfaceMessage.ifm_index) else {
                    continue
                }

                let sample = InterfaceSample(
                    name: name,
                    flags: UInt32(interfaceMessage.ifm_flags),
                    rxBytes: interfaceMessage.ifm_data.ifi_ibytes,
                    txBytes: interfaceMessage.ifm_data.ifi_obytes,
                    baudrate: interfaceMessage.ifm_data.ifi_baudrate
                )
                samples.append(sample)
            }
        }

        return samples
    }

    private static func fetchSamplesViaGetifaddrs() -> [InterfaceSample] {
        var samples: [InterfaceSample] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }

        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let addr = current?.pointee {
            defer { current = addr.ifa_next }

            guard let sa = addr.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let data = addr.ifa_data else { continue }

            let ifdata = data.assumingMemoryBound(to: if_data.self).pointee
            let name = String(cString: addr.ifa_name)

            let sample = InterfaceSample(
                name: name,
                flags: addr.ifa_flags,
                rxBytes: UInt64(ifdata.ifi_ibytes),
                txBytes: UInt64(ifdata.ifi_obytes),
                baudrate: UInt64(ifdata.ifi_baudrate)
            )
            samples.append(sample)
        }

        return samples
    }

    private static func interfaceName(for index: UInt16) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        let resolved = buffer.withUnsafeMutableBufferPointer {
            if_indextoname(UInt32(index), $0.baseAddress)
        }
        guard resolved != nil else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return "" }
            return String(cString: baseAddress)
        }
    }

    struct InterfaceInfo: Equatable, Sendable {
        let type: AdapterType
        let displayName: String
    }

    static func interfaceInfo() -> [String: InterfaceInfo] {
        guard let list = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var map: [String: InterfaceInfo] = [:]
        for iface in list {
            guard let bsdName = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            let type: AdapterType
            if let scType = SCNetworkInterfaceGetInterfaceType(iface) {
                if CFEqual(scType, kSCNetworkInterfaceTypeIEEE80211) {
                    type = .wifi
                } else if CFEqual(scType, kSCNetworkInterfaceTypeEthernet) {
                    type = .ethernet
                } else {
                    type = .other
                }
            } else {
                type = .other
            }
            let displayName = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? ?? bsdName
            map[bsdName] = InterfaceInfo(type: type, displayName: displayName)
        }
        return map
    }

    struct WifiInfo: Equatable, Sendable {
        let mode: String
        let txRate: Double
        let ssid: String?
        let detail: WifiDetail
    }

    static func wifiInfo() -> [String: WifiInfo] {
        let client = CWWiFiClient.shared()
        guard let interfaces = client.interfaces() else { return [:] }
        var map: [String: WifiInfo] = [:]
        for iface in interfaces {
            guard let name = iface.interfaceName else { continue }
            let mode = wifiModeString(for: iface)
            let rate = iface.transmitRate()
            let ssid = iface.ssid()
            let channel = iface.wlanChannel()
            let detail = WifiDetail(
                phyMode: phyModeString(iface.activePHYMode()),
                security: securityString(iface.security()),
                channelNumber: channel.map { Int($0.channelNumber) },
                channelWidth: channel.map { channelWidthString($0.channelWidth) },
                rssi: Int(iface.rssiValue()),
                noise: Int(iface.noiseMeasurement()),
                bssid: iface.bssid()
            )
            map[name] = WifiInfo(mode: mode, txRate: rate, ssid: ssid, detail: detail)
        }
        return map
    }

    static func wifiModeString(for iface: CWInterface) -> String {
        let band = iface.wlanChannel()?.channelBand
        switch band {
        case .band6GHz?: return "Wi-Fi (6 GHz)"
        case .band5GHz?: return "Wi-Fi (5 GHz)"
        case .band2GHz?: return "Wi-Fi (2.4 GHz)"
        default: return "Wi-Fi"
        }
    }

    private static func phyModeString(_ mode: CWPHYMode) -> String {
        switch mode.rawValue {
        case CWPHYMode.modeNone.rawValue: return "None"
        case CWPHYMode.mode11a.rawValue: return "802.11a"
        case CWPHYMode.mode11b.rawValue: return "802.11b"
        case CWPHYMode.mode11g.rawValue: return "802.11g"
        case CWPHYMode.mode11n.rawValue: return "Wi-Fi 4 (802.11n)"
        case CWPHYMode.mode11ac.rawValue: return "Wi-Fi 5 (802.11ac)"
        case CWPHYMode.mode11ax.rawValue: return "Wi-Fi 6 (802.11ax)"
        case 7: return "Wi-Fi 7 (802.11be)"
        default: return "Unknown"
        }
    }

    private static func securityString(_ security: CWSecurity) -> String {
        switch security {
        case .none: return "Open"
        case .WEP: return "WEP"
        case .wpaPersonal: return "WPA Personal"
        case .wpaPersonalMixed: return "WPA/WPA2 Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .personal: return "WPA3 Personal"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Transition: return "WPA2/WPA3 Personal"
        case .dynamicWEP: return "Dynamic WEP"
        case .wpaEnterprise: return "WPA Enterprise"
        case .wpaEnterpriseMixed: return "WPA/WPA2 Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .enterprise: return "WPA3 Enterprise"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .OWE: return "OWE"
        case .oweTransition: return "OWE Transition"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    private static func channelWidthString(_ width: CWChannelWidth) -> String {
        switch width {
        case .width20MHz: return "20 MHz"
        case .width40MHz: return "40 MHz"
        case .width80MHz: return "80 MHz"
        case .width160MHz: return "160 MHz"
        case .widthUnknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    static func rate(current: UInt64, previous: UInt64?, deltaTime: Double) -> Double {
        guard let previous, deltaTime > 0 else { return 0 }
        let delta = current >= previous ? current - previous : 0
        return Double(delta) / deltaTime
    }

    static func defaultGatewayIP(store: SCDynamicStore? = nil) -> String {
        let s = store ?? SCDynamicStoreCreate(nil, "NetFluss" as CFString, nil, nil)
        let key = SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv4)
        guard let dict = SCDynamicStoreCopyValue(s, key) as? [String: Any],
              let router = dict[kSCPropNetIPv4Router as String] as? String,
              !router.isEmpty else { return "—" }
        return router
    }

    static func primaryInternalIP() -> String {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return "—" }
        defer { freeifaddrs(pointer) }

        var fallback: String?
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current?.pointee {
            defer { current = entry.ifa_next }
            guard let sa = entry.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0,
                  (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &hostname, socklen_t(NI_MAXHOST),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = hostname.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            guard !ip.isEmpty, ip != "0.0.0.0", !ip.hasPrefix("169.254") else { continue }
            let ifName = String(cString: entry.ifa_name)
            if ifName == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback ?? "—"
    }
}
