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
import CoreWLAN
import SystemConfiguration

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published var adapters: [AdapterStatus] = []
    @Published var totals = RateTotals(rxRateBps: 0, txRateBps: 0)
    @Published var topApps: [AppTraffic] = []
    @Published var reconnectingAdapters: Set<String> = []
    @Published var adapterGraceDeadlines: [String: Date] = [:]
    @Published var internalIP: String = "—"
    @Published var gatewayIP: String = "—"
    @Published var externalIP: String = "—"
    @Published var externalIPCountryCode: String = ""

    private var timer: DispatchSourceTimer?
    private var lastSample: [String: InterfaceSample] = [:]
    private var lastUpdate: Date?
    private var currentInterval: Double?
    private var lastExternalIPUpdate: Date?
    private var externalIPInFlight = false
    private var processSnapshot: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var processSnapshotTime: Date?
    private var topAppsTaskInFlight = false
    private var adapterLastActiveTime: [String: Date] = [:]
    private var topAppLastActiveTime: [String: (lastSeen: Date, rxRate: Double, txRate: Double)] = [:]

    func start(interval: Double) {
        let clamped = max(0.2, min(interval, 10.0))
        if currentInterval == clamped, timer != nil { return }
        currentInterval = clamped

        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: clamped)
        timer.setEventHandler { [weak self] in
            self?.refresh()
        }
        timer.resume()
        self.timer = timer
    }

    private func refresh() {
        let now = Date()
        let samples = InterfaceSampler.fetchSamples()
        let infoMap = InterfaceSampler.interfaceInfo()
        let wifiInfoMap = InterfaceSampler.wifiInfo()

        var updatedAdapters: [AdapterStatus] = []
        var totalRxRate: Double = 0
        var totalTxRate: Double = 0

        for sample in samples {
            let previous = lastSample[sample.name]
            let deltaTime = now.timeIntervalSince(lastUpdate ?? now)

            let rxRate = InterfaceSampler.rate(current: sample.rxBytes, previous: previous?.rxBytes, deltaTime: deltaTime)
            let txRate = InterfaceSampler.rate(current: sample.txBytes, previous: previous?.txBytes, deltaTime: deltaTime)

            let info = infoMap[sample.name]
            let type = info?.type ?? .other
            let displayName = info?.displayName ?? sample.name
            let wifiInfo = wifiInfoMap[sample.name]
            let isUp = (sample.flags & UInt32(IFF_UP)) != 0
            let linkSpeed = type == .ethernet ? sample.baudrate : nil

            let adapter = AdapterStatus(
                id: sample.name,
                displayName: displayName,
                type: type,
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

        adapters = updatedAdapters.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        totals = RateTotals(rxRateBps: totalRxRate, txRateBps: totalTxRate)
        lastSample = Dictionary(uniqueKeysWithValues: samples.map { ($0.name, $0) })
        lastUpdate = now

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
            adapterGraceDeadlines = deadlines
        } else {
            if !adapterGraceDeadlines.isEmpty { adapterGraceDeadlines = [:] }
        }

        // Clean up tracking for adapters no longer returned by getifaddrs
        adapterLastActiveTime = adapterLastActiveTime.filter { currentAdapterIDs.contains($0.key) }

        updateTopApps()
        updateIPsIfNeeded()
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

        Task { [weak self] in
            let sampleTime = Date()
            let snapshot = await Task.detached(priority: .utility) {
                ProcessNetworkSampler.sample()
            }.value

            guard let self else { return }
            self.topAppsTaskInFlight = false

            if let prevTime = previousTime, !previousSnapshot.isEmpty {
                let elapsed = sampleTime.timeIntervalSince(prevTime)
                if elapsed >= 0.1 {
                    var apps = ProcessNetworkSampler.rates(
                        current: snapshot,
                        previous: previousSnapshot,
                        elapsed: elapsed,
                        limit: 5
                    )

                    let topAppsGraceEnabled = UserDefaults.standard.bool(forKey: "topAppsGracePeriodEnabled")
                    let topAppsGraceSeconds = UserDefaults.standard.double(forKey: "topAppsGracePeriodSeconds")
                    let now = Date()

                    // Update last-active tracking for currently active apps
                    let activeNames = Set(apps.map(\.name))
                    for app in apps {
                        self.topAppLastActiveTime[app.name] = (lastSeen: now, rxRate: app.rxRateBps, txRate: app.txRateBps)
                    }

                    if topAppsGraceEnabled {
                        // Re-insert recently-active apps that are no longer active
                        for (name, entry) in self.topAppLastActiveTime {
                            if activeNames.contains(name) { continue }
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

                    self.topApps = apps
                }
            }

            self.processSnapshot = snapshot
            self.processSnapshotTime = sampleTime
        }
    }

    // MARK: - IP Addresses

    private func updateIPsIfNeeded() {
        internalIP = InterfaceSampler.primaryInternalIP()
        gatewayIP = InterfaceSampler.defaultGatewayIP()

        let now = Date()
        if let lastExternalIPUpdate, now.timeIntervalSince(lastExternalIPUpdate) < 60.0 { return }
        guard !externalIPInFlight else { return }

        externalIPInFlight = true
        Task { [weak self] in
            let result = await Self.fetchExternalIP()
            guard let self else { return }
            self.externalIP = result?.ip ?? "—"
            self.externalIPCountryCode = result?.countryCode ?? ""
            self.lastExternalIPUpdate = Date()
            self.externalIPInFlight = false
        }
    }

    private static func fetchExternalIP() async -> (ip: String, countryCode: String)? {
        guard let url = URL(string: "https://ipapi.co/json/") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Netfluss/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = json["ip"] as? String else { return nil }
        let country = json["country_code"] as? String ?? ""
        return (ip: ip, countryCode: country)
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
                let script = "do shell script \"ifconfig \(bsdName) down && sleep 1 && ifconfig \(bsdName) up\" with administrator privileges"
                Self.runSync("/usr/bin/osascript", ["-e", script])
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

    private nonisolated static func runSync(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }

    private nonisolated static func runSyncOutput(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        // Read before waitUntilExit to avoid pipe-buffer deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Process Network Sampler

enum ProcessNetworkSampler {

    /// Snapshot: cumulative inet bytes per process name at a point in time.
    /// Uses `netstat -n -b -v` which exposes per-connection rxbytes/txbytes with process:pid.
    static func sample() -> [String: (rx: UInt64, tx: UInt64)] {
        let output = runNetstat()
        var pidBytes: [pid_t: (rx: UInt64, tx: UInt64)] = [:]

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 8 else { continue }
            let isTCP = parts[0].hasPrefix("tcp")
            let isUDP = parts[0].hasPrefix("udp")
            guard isTCP || isUDP else { continue }

            // TCP: proto recv-q send-q local foreign STATE rxbytes txbytes ...
            // UDP: proto recv-q send-q local foreign rxbytes txbytes ...
            let rxIndex = isTCP ? 6 : 5
            let txIndex = isTCP ? 7 : 6
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

            let prev = pidBytes[pid] ?? (rx: 0, tx: 0)
            pidBytes[pid] = (rx: prev.rx + rx, tx: prev.tx + tx)
        }

        // Resolve PIDs to clean display names via proc_pidpath
        var result: [String: (rx: UInt64, tx: UInt64)] = [:]
        for (pid, bytes) in pidBytes {
            let name = processName(for: pid) ?? "PID \(pid)"
            let prev = result[name] ?? (rx: 0, tx: 0)
            result[name] = (rx: prev.rx + bytes.rx, tx: prev.tx + bytes.tx)
        }
        return result
    }

    /// Convert two snapshots into per-second rates, sorted by total traffic.
    static func rates(current: [String: (rx: UInt64, tx: UInt64)],
                      previous: [String: (rx: UInt64, tx: UInt64)],
                      elapsed: Double,
                      limit: Int) -> [AppTraffic] {
        var apps: [AppTraffic] = []

        for (name, curr) in current {
            let prev = previous[name] ?? (rx: 0, tx: 0)
            // Guard against counter reset (connection closed/reopened)
            let rxDelta = curr.rx >= prev.rx ? curr.rx - prev.rx : curr.rx
            let txDelta = curr.tx >= prev.tx ? curr.tx - prev.tx : curr.tx
            let rxRate = Double(rxDelta) / elapsed
            let txRate = Double(txDelta) / elapsed
            guard rxRate > 0 || txRate > 0 else { continue }
            apps.append(AppTraffic(id: name, name: name, rxRateBps: rxRate, txRateBps: txRate))
        }

        return apps
            .sorted { ($0.rxRateBps + $0.txRateBps) > ($1.rxRateBps + $1.txRateBps) }
            .prefix(limit)
            .map { $0 }
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

    /// Best-effort process name: tries full path (for clean app names), falls back to proc_name.
    private static func processName(for pid: pid_t) -> String? {
        var pathBuf = [CChar](repeating: 0, count: Int(PATH_MAX) * 4)
        let pathLen = pathBuf.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        if pathLen > 0 {
            let path = pathBuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            // Strip .app bundle path: ".../Safari.app/Contents/MacOS/Safari" → "Safari"
            let url = URL(fileURLWithPath: path)
            if let appRange = path.range(of: ".app/", options: .caseInsensitive) {
                let appPath = String(path[path.startIndex..<appRange.lowerBound])
                let name = URL(fileURLWithPath: appPath).lastPathComponent
                if !name.isEmpty { return name }
            }
            let name = url.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        }

        var nameBuf = [CChar](repeating: 0, count: 1024)
        let nameLen = nameBuf.withUnsafeMutableBytes {
            proc_name(pid, $0.baseAddress, UInt32($0.count))
        }
        guard nameLen > 0 else { return nil }
        return nameBuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}

// MARK: - Interface Sampler

enum InterfaceSampler {
    static func fetchSamples() -> [InterfaceSample] {
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

    struct InterfaceInfo {
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

    struct WifiInfo {
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
        switch mode {
        case .modeNone: return "None"
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "Wi-Fi 4 (802.11n)"
        case .mode11ac: return "Wi-Fi 5 (802.11ac)"
        case .mode11ax: return "Wi-Fi 6 (802.11ax)"
        @unknown default: return "Unknown"
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

    static func defaultGatewayIP() -> String {
        let store = SCDynamicStoreCreate(nil, "Netfluss" as CFString, nil, nil)
        let key = SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv4)
        guard let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any],
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
