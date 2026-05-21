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

import AppKit
import CoreLocation
import CoreWLAN
import Foundation

enum WifiLocationStatus {
    case notDetermined
    case denied            // user denied, or system Location services off
    case authorized
}

@MainActor
final class WifiManager: NSObject, ObservableObject {
    @Published private(set) var networks: [WifiNetwork] = []
    @Published private(set) var currentSSID: String?
    @Published private(set) var connectingTo: String?    // SSID being joined
    @Published private(set) var lastError: String?
    @Published private(set) var locationStatus: WifiLocationStatus = .notDetermined
    @Published private(set) var pinnedSSIDs: [String] = []   // last pinned first

    private static let pinnedDefaultsKey = "pinnedWifiSSIDs"

    private let interface: CWInterface?
    private let locationManager = CLLocationManager()
    private var cwNetworksByID: [String: CWNetwork] = [:]
    private var refreshTimer: DispatchSourceTimer?
    private var isActive = false
    private var pendingFreshScan = false
    private static let refreshInterval: TimeInterval = 8

    override init() {
        self.interface = CWWiFiClient.shared().interface()
        super.init()
        locationManager.delegate = self
        updateLocationStatus(from: locationManager.authorizationStatus)
        pinnedSSIDs = UserDefaults.standard.stringArray(forKey: Self.pinnedDefaultsKey) ?? []
    }

    deinit {
        refreshTimer?.cancel()
    }

    var hasWifi: Bool { interface != nil }

    // Toggled by the StatusBarController as the popover opens/closes.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            ensureLocationAuthorizationOrRefresh()
            startTimer()
        } else {
            stopTimer()
        }
    }

    /// Opens System Settings → Privacy & Security → Location Services so the
    /// user can grant access when they previously denied or when system-wide
    /// Location is disabled.
    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    private func ensureLocationAuthorizationOrRefresh() {
        switch locationStatus {
        case .notDetermined:
            // requestWhenInUseAuthorization alone does NOT reliably surface the
            // TCC prompt for LSUIElement (menu-bar) apps — tccd shows the
            // prompt only when the app is actually trying to use location.
            // Kicking off an update forces it; we stop the update again as
            // soon as the authorization changes (see CLLocationManagerDelegate).
            locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
            locationManager.requestWhenInUseAuthorization()
            locationManager.startUpdatingLocation()
        case .authorized:
            triggerFreshScan()
            refresh()
        case .denied:
            // Still publish whatever cachedScanResults gives (often empty / only
            // current SSID) and let the UI show the "Grant Location access" hint.
            refresh()
        }
    }

    private func triggerFreshScan() {
        guard let interface, !pendingFreshScan else { return }
        pendingFreshScan = true
        Task.detached(priority: .userInitiated) { [weak self] in
            // scanForNetworks(withSSID:) is synchronous; runs ~1 s.
            _ = try? interface.scanForNetworks(withSSID: nil)
            await self?.finishFreshScan()
        }
    }

    private func finishFreshScan() {
        pendingFreshScan = false
        refresh()
    }

    func refresh() {
        guard let interface else { return }
        let currentSSID = interface.ssid()
        self.currentSSID = currentSSID

        let savedSSIDs: Set<String> = {
            guard let profiles = interface.configuration()?.networkProfiles else { return [] }
            return Set(profiles.compactMap { ($0 as? CWNetworkProfile)?.ssid })
        }()

        let cwNetworks = interface.cachedScanResults() ?? []
        let activeBSSID = interface.bssid()

        // Group scan results by SSID — mesh / dual-band routers broadcast the
        // same name on multiple BSSIDs and we want one row per network, not
        // one per radio. Within each group we keep the strongest BSSID as the
        // canonical row that gets connected to and inspected.
        var bestPerSSID: [String: (net: WifiNetwork, cw: CWNetwork)] = [:]

        for net in cwNetworks {
            guard let ssid = net.ssid, !ssid.isEmpty else { continue }
            let rssi = Int(net.rssiValue)

            // Skip if we already have a stronger BSSID for this SSID — unless
            // this one is the currently-associated BSSID, which always wins so
            // the (i) popover shows the active link's details.
            if let existing = bestPerSSID[ssid] {
                let thisIsActive = net.bssid != nil && net.bssid == activeBSSID
                let existingIsActive = existing.net.bssid != nil && existing.net.bssid == activeBSSID
                if existingIsActive { continue }
                if !thisIsActive, rssi <= (existing.net.rssi ?? Int.min) { continue }
            }

            let security = Self.detectSecurity(on: net)
            let channel = net.wlanChannel
            let bandStr: String? = {
                guard let band = channel?.channelBand else { return nil }
                switch band {
                case .band2GHz: return "2.4 GHz"
                case .band5GHz: return "5 GHz"
                case .band6GHz: return "6 GHz"
                default: return nil
                }
            }()

            let isCurrentRow: Bool = {
                guard ssid == currentSSID else { return false }
                if let activeBSSID, let bssid = net.bssid {
                    return bssid == activeBSSID
                }
                // No BSSID info — fall back to SSID match (single match because
                // we collapse by SSID below).
                return true
            }()

            bestPerSSID[ssid] = (
                WifiNetwork(
                    id: ssid,
                    ssid: ssid,
                    bssid: net.bssid,
                    rssi: rssi,
                    isSecured: security != .none,
                    security: Self.securityString(security),
                    channelNumber: channel.map { Int($0.channelNumber) },
                    channelWidth: channel.map { Self.channelWidthString($0.channelWidth) },
                    band: bandStr,
                    isCurrent: isCurrentRow,
                    isSaved: savedSSIDs.contains(ssid),
                    isPinned: pinnedSSIDs.contains(ssid),
                    isAvailable: true
                ),
                net
            )
        }

        var collected = Array(bestPerSSID.values)

        // Make sure the currently-connected network is present even if it wasn't
        // included in this scan window (which happens occasionally).
        if let currentSSID, !collected.contains(where: { $0.net.ssid == currentSSID }) {
            collected.insert(
                (
                    WifiNetwork(
                        id: currentSSID,
                        ssid: currentSSID,
                        bssid: activeBSSID,
                        rssi: Int(interface.rssiValue()),
                        isSecured: interface.security() != .none,
                        security: Self.securityString(interface.security()),
                        channelNumber: interface.wlanChannel().map { Int($0.channelNumber) },
                        channelWidth: interface.wlanChannel().map { Self.channelWidthString($0.channelWidth) },
                        band: {
                            switch interface.wlanChannel()?.channelBand {
                            case .band2GHz?: return "2.4 GHz"
                            case .band5GHz?: return "5 GHz"
                            case .band6GHz?: return "6 GHz"
                            default: return nil
                            }
                        }(),
                        isCurrent: true,
                        isSaved: savedSSIDs.contains(currentSSID),
                        isPinned: pinnedSSIDs.contains(currentSSID),
                        isAvailable: true
                    ),
                    // No CWNetwork object for the active connection; connect()
                    // short-circuits if it's already current so this is unused.
                    CWNetwork()
                ),
                at: 0
            )
        }

        // Synthesise placeholder rows for any pinned SSID that isn't visible
        // right now, so the user can still see (and try to reconnect to) it.
        for ssid in pinnedSSIDs where !collected.contains(where: { $0.net.ssid == ssid }) {
            collected.append(
                (
                    WifiNetwork(
                        id: ssid,
                        ssid: ssid,
                        bssid: nil,
                        rssi: nil,
                        isSecured: true,            // assume secured; harmless if not
                        security: nil,
                        channelNumber: nil,
                        channelWidth: nil,
                        band: nil,
                        isCurrent: false,
                        isSaved: savedSSIDs.contains(ssid),
                        isPinned: true,
                        isAvailable: false
                    ),
                    CWNetwork()
                )
            )
        }

        // Sort order:
        //   1. Pinned networks, most-recently-pinned first.
        //   2. Currently-connected (when it isn't already pinned).
        //   3. Everything else by descending RSSI.
        let pinIndex: (String) -> Int = { [pinnedSSIDs] ssid in
            pinnedSSIDs.firstIndex(of: ssid) ?? Int.max
        }
        collected.sort { lhs, rhs in
            if lhs.net.isPinned != rhs.net.isPinned { return lhs.net.isPinned }
            if lhs.net.isPinned, rhs.net.isPinned {
                return pinIndex(lhs.net.ssid) < pinIndex(rhs.net.ssid)
            }
            if lhs.net.isCurrent != rhs.net.isCurrent { return lhs.net.isCurrent }
            let lr = lhs.net.rssi ?? Int.min
            let rr = rhs.net.rssi ?? Int.min
            return lr > rr
        }

        self.networks = collected.map(\.net)
        self.cwNetworksByID = Dictionary(uniqueKeysWithValues: collected.map { ($0.net.id, $0.cw) })
    }

    func connect(to network: WifiNetwork) {
        guard let interface else { return }
        if network.isCurrent { return }
        guard connectingTo == nil else { return }

        // Offline pinned: rescan for the SSID and pick whichever BSSID
        // answered. If nothing answers, surface a clear error.
        if !network.isAvailable {
            attemptAssociateOfflinePinned(interface: interface, network: network)
            return
        }

        if network.isSecured && !network.isSaved {
            promptForPasswordAndConnect(interface: interface, network: network)
        } else {
            attemptAssociate(interface: interface, network: network, password: nil)
        }
    }

    func togglePin(_ network: WifiNetwork) {
        if pinnedSSIDs.contains(network.ssid) {
            unpin(network.ssid)
        } else {
            pin(network.ssid)
        }
    }

    func pin(_ ssid: String) {
        guard !ssid.isEmpty else { return }
        var list = pinnedSSIDs
        list.removeAll { $0 == ssid }
        list.insert(ssid, at: 0)
        pinnedSSIDs = list
        UserDefaults.standard.set(list, forKey: Self.pinnedDefaultsKey)
        refresh()
    }

    func unpin(_ ssid: String) {
        let list = pinnedSSIDs.filter { $0 != ssid }
        guard list.count != pinnedSSIDs.count else { return }
        pinnedSSIDs = list
        UserDefaults.standard.set(list, forKey: Self.pinnedDefaultsKey)
        refresh()
    }

    func clearError() { lastError = nil }

    // MARK: - Password prompt

    private func promptForPasswordAndConnect(interface: CWInterface, network: WifiNetwork) {
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Connect to %@", comment: ""), network.ssid)
        if let security = network.security {
            alert.informativeText = String(
                format: NSLocalizedString("Enter the password for this %@ network.", comment: ""),
                security
            )
        } else {
            alert.informativeText = NSLocalizedString("Enter the network password.", comment: "")
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Join", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        let secureField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        secureField.placeholderString = NSLocalizedString("Password", comment: "")
        alert.accessoryView = secureField
        alert.window.initialFirstResponder = secureField

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let password = secureField.stringValue
        attemptAssociate(interface: interface, network: network, password: password)
    }

    private func attemptAssociateOfflinePinned(interface: CWInterface, network: WifiNetwork) {
        connectingTo = network.ssid
        lastError = nil

        let ssid = network.ssid
        let ssidData = Data(ssid.utf8)
        Task.detached(priority: .userInitiated) { [weak self] in
            let found: CWNetwork? = {
                do {
                    let results = try interface.scanForNetworks(withSSID: ssidData)
                    return results.first(where: { $0.ssid == ssid })
                } catch {
                    return nil
                }
            }()

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let found else {
                    self.connectingTo = nil
                    self.lastError = NSLocalizedString("Network is not in range right now.", comment: "")
                    return
                }
                // Splice the discovered CWNetwork into the lookup map and
                // re-enter the normal connect flow.
                self.cwNetworksByID[network.ssid] = found
                let promoted = WifiNetwork(
                    id: network.ssid,
                    ssid: network.ssid,
                    bssid: found.bssid,
                    rssi: Int(found.rssiValue),
                    isSecured: !found.supportsSecurity(.none),
                    security: Self.securityString(Self.detectSecurity(on: found)),
                    channelNumber: found.wlanChannel.map { Int($0.channelNumber) },
                    channelWidth: found.wlanChannel.map { Self.channelWidthString($0.channelWidth) },
                    band: nil,
                    isCurrent: false,
                    isSaved: network.isSaved,
                    isPinned: true,
                    isAvailable: true
                )
                self.connectingTo = nil
                self.connect(to: promoted)
            }
        }
    }

    private func attemptAssociate(interface: CWInterface, network: WifiNetwork, password: String?) {
        guard let cwNetwork = cwNetworksByID[network.id] else {
            lastError = NSLocalizedString("Network is no longer in range.", comment: "")
            return
        }
        connectingTo = network.ssid
        lastError = nil

        let interfaceName = interface.interfaceName ?? ""
        let shouldPersist = !network.isSaved
        let networksetupSecurityType = Self.networksetupSecurityType(for: cwNetwork)

        // associate(toNetwork:password:) is synchronous and blocking — run on a
        // background queue and hop back to the main actor for state updates.
        Task.detached(priority: .userInitiated) { [weak self] in
            let failure: String? = {
                do {
                    try interface.associate(to: cwNetwork, password: password)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }()

            // associate only joins for this session — to make the network
            // "remembered" the way a system Wi-Fi menu join is (Known Networks
            // entry + system keychain password), the privileged helper runs
            // `networksetup -addpreferredwirelessnetworkatindex` after a
            // successful association.
            if failure == nil,
               shouldPersist,
               !interfaceName.isEmpty,
               let securityType = networksetupSecurityType {
                _ = await PrivilegedHelperManager.shared.savePreferredWifiNetwork(
                    interfaceName: interfaceName,
                    ssid: network.ssid,
                    networksetupSecurityType: securityType,
                    password: password
                )
            }

            await self?.finishAssociate(error: failure)
        }
    }

    private func finishAssociate(error: String?) {
        connectingTo = nil
        lastError = error
        refresh()
    }

    /// Maps a scanned CWNetwork's advertised security to the string accepted by
    /// `networksetup -addpreferredwirelessnetworkatindex`. Returns nil if the
    /// security mode isn't supported by that command (in which case we still
    /// associate for this session but skip the persistence step).
    private static func networksetupSecurityType(for net: CWNetwork) -> String? {
        // Order matters: probe strongest mode first.
        if net.supportsSecurity(.wpa3Personal) || net.supportsSecurity(.personal) {
            return "WPA3"
        }
        if net.supportsSecurity(.wpa3Transition) {
            // WPA2/WPA3 transition APs accept either; "WPA2" is the safer
            // string for older clients/networksetup.
            return "WPA2"
        }
        if net.supportsSecurity(.wpa2Personal) || net.supportsSecurity(.wpaPersonalMixed) {
            return "WPA2"
        }
        if net.supportsSecurity(.wpaPersonal) { return "WPA" }
        if net.supportsSecurity(.WEP) || net.supportsSecurity(.dynamicWEP) { return "WEP" }
        if net.supportsSecurity(.wpa2Enterprise) || net.supportsSecurity(.wpaEnterpriseMixed) {
            return "WPA2E"
        }
        if net.supportsSecurity(.wpaEnterprise) { return "WPAE" }
        if net.supportsSecurity(.none) { return "OPEN" }
        return nil
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + Self.refreshInterval, repeating: Self.refreshInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.locationStatus == .authorized {
                self.triggerFreshScan()
            } else {
                self.refresh()
            }
        }
        timer.resume()
        refreshTimer = timer
    }

    private func stopTimer() {
        refreshTimer?.cancel()
        refreshTimer = nil
    }

    // MARK: - Helpers

    private static func detectSecurity(on net: CWNetwork) -> CWSecurity {
        // CWNetwork.supportsSecurity(_:) returns true for the security type
        // the network advertises. Probe in descending strength order so we
        // report the strongest mode the network supports.
        let order: [CWSecurity] = [
            .wpa3Enterprise, .enterprise, .wpa3Personal, .personal,
            .wpa3Transition, .wpa2Enterprise, .wpaEnterpriseMixed, .wpaEnterprise,
            .wpa2Personal, .wpaPersonalMixed, .wpaPersonal,
            .OWE, .oweTransition, .dynamicWEP, .WEP, .none
        ]
        for candidate in order where net.supportsSecurity(candidate) {
            return candidate
        }
        return .unknown
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

    fileprivate func updateLocationStatus(from raw: CLAuthorizationStatus) {
        let mapped: WifiLocationStatus
        switch raw {
        case .notDetermined:
            mapped = .notDetermined
        case .restricted, .denied:
            mapped = .denied
        case .authorizedAlways, .authorizedWhenInUse:
            mapped = .authorized
        @unknown default:
            mapped = .denied
        }
        if mapped != locationStatus {
            locationStatus = mapped
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
}

extension WifiManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateLocationStatus(from: status)
            // We only kicked off updates to trigger the prompt; once we have a
            // decision (either way) the location stream is no longer needed.
            self.locationManager.stopUpdatingLocation()
            if self.locationStatus == .authorized {
                self.triggerFreshScan()
            }
            self.refresh()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Treat any location-update error as "we got our prompt response" —
        // CoreLocation often returns kCLErrorDenied here when the user closes
        // the prompt with deny. Stop the stream so we don't leak the radio.
        Task { @MainActor [weak self] in
            self?.locationManager.stopUpdatingLocation()
        }
    }
}
