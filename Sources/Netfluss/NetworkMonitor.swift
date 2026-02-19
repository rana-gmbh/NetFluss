import Foundation
import CoreWLAN
import SystemConfiguration

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published var adapters: [AdapterStatus] = []
    @Published var totals = RateTotals(rxRateBps: 0, txRateBps: 0)
    @Published var topApps: [AppTraffic] = []
    @Published var topAppsError: String? = nil
    @Published var internalIP: String = "—"
    @Published var externalIP: String = "—"

    private var timer: DispatchSourceTimer?
    private var lastSample: [String: InterfaceSample] = [:]
    private var lastUpdate: Date?
    private var currentInterval: Double?
    private var lastTopAppsUpdate: Date?
    private var topAppsInFlight = false
    private var lastExternalIPUpdate: Date?
    private var externalIPInFlight = false

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
        let typeMap = InterfaceSampler.interfaceTypes()
        let displayMap = InterfaceSampler.interfaceDisplayNames()
        let wifiInfoMap = InterfaceSampler.wifiInfo()

        var updatedAdapters: [AdapterStatus] = []
        var totalRxRate: Double = 0
        var totalTxRate: Double = 0

        for sample in samples {
            let previous = lastSample[sample.name]
            let deltaTime = now.timeIntervalSince(lastUpdate ?? now)

            let rxRate = InterfaceSampler.rate(current: sample.rxBytes, previous: previous?.rxBytes, deltaTime: deltaTime)
            let txRate = InterfaceSampler.rate(current: sample.txBytes, previous: previous?.txBytes, deltaTime: deltaTime)

            let type = typeMap[sample.name] ?? .other
            let displayName = displayMap[sample.name] ?? sample.name

            let wifiInfo = wifiInfoMap[sample.name]

            let isUp = (sample.flags & UInt32(IFF_UP)) != 0
            let linkSpeed = type == .ethernet ? sample.baudrate : nil

            let adapter = AdapterStatus(
                id: sample.name,
                name: sample.name,
                displayName: displayName,
                type: type,
                isUp: isUp,
                linkSpeedBps: linkSpeed,
                wifiMode: wifiInfo?.mode,
                wifiTxRateMbps: wifiInfo?.txRate,
                wifiSSID: wifiInfo?.ssid,
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

        updateTopAppsIfNeeded()
        updateIPsIfNeeded()
    }

    private func updateIPsIfNeeded() {
        internalIP = InterfaceSampler.primaryInternalIP()

        let now = Date()
        if let lastExternalIPUpdate, now.timeIntervalSince(lastExternalIPUpdate) < 60.0 { return }
        guard !externalIPInFlight else { return }

        externalIPInFlight = true
        Task { [weak self] in
            let ip = await Self.fetchExternalIP()
            guard let self else { return }
            self.externalIP = ip ?? "—"
            self.lastExternalIPUpdate = Date()
            self.externalIPInFlight = false
        }
    }

    private static func fetchExternalIP() async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateTopAppsIfNeeded() {
        let showTopApps = UserDefaults.standard.bool(forKey: "showTopApps")
        guard showTopApps else {
            if !topApps.isEmpty {
                topApps = []
            }
            return
        }

        let now = Date()
        if let lastTopAppsUpdate, now.timeIntervalSince(lastTopAppsUpdate) < 2.0 { return }
        guard !topAppsInFlight else { return }

        topAppsInFlight = true
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                AppTrafficSampler.fetchTopApps(limit: 10)
            }.value

            guard let self else { return }
            switch result {
            case .success(let apps):
                self.topApps = apps
                self.topAppsError = nil
            case .failure(let error):
                self.topApps = []
                self.topAppsError = error.localizedDescription
            }
            self.lastTopAppsUpdate = Date()
            self.topAppsInFlight = false
        }
    }
}

enum AppTrafficSampler {
    enum AppTrafficError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let value):
                return value
            }
        }
    }

    static func fetchTopApps(limit: Int) -> Result<[AppTraffic], AppTrafficError> {
        let result = runNettop()
        guard !result.output.isEmpty else {
            let reason = result.error.isEmpty ? "nettop returned no data (NStat may be restricted)." : result.error
            return .failure(.message(reason))
        }

        let lines = result.output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2 else { return .failure(.message("nettop output was incomplete.")) }

        let header = splitCSV(lines[0])
        let rows = lines.dropFirst()

        let processIndex = indexOfColumn(in: header, candidates: ["process", "proc", "comm", "name"])
        let inIndex = indexOfColumn(in: header, candidates: ["bytes_in", "rx_bytes", "in_bytes", "bytes-in", "recv_bytes", "rcv_bytes"])
        let outIndex = indexOfColumn(in: header, candidates: ["bytes_out", "tx_bytes", "out_bytes", "bytes-out", "sent_bytes", "snd_bytes"])

        guard let processIndex, let inIndex, let outIndex else {
            return .failure(.message("nettop columns not found. Output format may have changed."))
        }

        var totals: [String: (rx: Double, tx: Double)] = [:]

        for row in rows {
            let cols = splitCSV(row)
            if cols.count <= max(processIndex, inIndex, outIndex) { continue }
            let name = cols[processIndex].isEmpty ? "Unknown" : cols[processIndex]
            let rx = Double(cols[inIndex]) ?? 0
            let tx = Double(cols[outIndex]) ?? 0
            let current = totals[name] ?? (0, 0)
            totals[name] = (current.rx + rx, current.tx + tx)
        }

        let sorted = totals.map { AppTraffic(id: $0.key, name: $0.key, rxRateBps: $0.value.rx, txRateBps: $0.value.tx) }
            .sorted { ($0.rxRateBps + $0.txRateBps) > ($1.rxRateBps + $1.txRateBps) }

        return .success(Array(sorted.prefix(limit)))
    }

    private static func runNettop() -> (output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-n", "-x"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ("", "Failed to run nettop.")
        }

        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8) ?? ""
        let error = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else { return ("", error) }
        return (output, error)
    }

    private static func indexOfColumn(in header: [String], candidates: [String]) -> Int? {
        let lower = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        for candidate in candidates {
            if let index = lower.firstIndex(where: { $0 == candidate || $0.contains(candidate) }) {
                return index
            }
        }
        return nil
    }

    private static func splitCSV(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
                continue
            }
            if char == "," && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)
        return result
    }
}

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

    static func interfaceTypes() -> [String: AdapterType] {
        guard let list = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var map: [String: AdapterType] = [:]
        for iface in list {
            guard let bsdName = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            if let type = SCNetworkInterfaceGetInterfaceType(iface) {
                if CFEqual(type, kSCNetworkInterfaceTypeIEEE80211) {
                    map[bsdName] = .wifi
                } else if CFEqual(type, kSCNetworkInterfaceTypeEthernet) {
                    map[bsdName] = .ethernet
                } else {
                    map[bsdName] = .other
                }
            } else {
                map[bsdName] = .other
            }
        }
        return map
    }

    static func interfaceDisplayNames() -> [String: String] {
        guard let list = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var map: [String: String] = [:]
        for iface in list {
            guard let bsdName = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            if let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
                map[bsdName] = name
            }
        }
        return map
    }

    struct WifiInfo {
        let mode: String
        let txRate: Double
        let ssid: String?
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
            map[name] = WifiInfo(mode: mode, txRate: rate, ssid: ssid)
        }
        return map
    }

    static func wifiModeString(for iface: CWInterface) -> String {
        let band = iface.wlanChannel()?.channelBand
        switch band {
        case .band6GHz?:
            return "Wi-Fi (6 GHz)"
        case .band5GHz?:
            return "Wi-Fi (5 GHz)"
        case .band2GHz?:
            return "Wi-Fi (2.4 GHz)"
        case .bandUnknown?:
            return "Wi-Fi"
        case nil:
            return "Wi-Fi"
        @unknown default:
            return "Wi-Fi"
        }
    }

    static func rate(current: UInt64, previous: UInt64?, deltaTime: Double) -> Double {
        guard let previous, deltaTime > 0 else { return 0 }
        let delta = current >= previous ? current - previous : 0
        return Double(delta) / deltaTime
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
