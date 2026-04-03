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

@MainActor
final class AppState {
    let monitor: NetworkMonitor
    let statusBar: StatusBarController
    let updateNotifier: UpdateNotifier
    private var defaultsObserver: NSObjectProtocol?

    init() {
        UserDefaults.standard.register(defaults: [
            "refreshInterval": 1.0,
            "showInactive": false,
            "showOtherAdapters": false,
            "useBits": false,
            "hiddenAdapters": [],
            "showTopApps": false,
            "uploadColor": "green",
            "uploadColorHex": "",
            "downloadColor": "blue",
            "downloadColorHex": "",
            "menuBarUploadTextColor": "green",
            "menuBarUploadTextColorHex": "",
            "menuBarDownloadTextColor": "blue",
            "menuBarDownloadTextColorHex": "",
            "theme": "system",
            "menuBarFontSize": 10.0,
            "menuBarFontDesign": "monospaced",
            "adapterOrder": [],
            "adapterCustomNames": Data(),
            "menuBarMode": "rates",
            "menuBarIconSymbol": "network",
            "menuBarPinnedUnit": "auto",
            "menuBarDecimals": 0,
            "totalsOnlyVisibleAdapters": false,
            "excludeTunnelAdaptersFromTotals": false,
            "adapterGracePeriodEnabled": false,
            "adapterGracePeriodSeconds": 3.0,
            "topAppsGracePeriodEnabled": false,
            "topAppsGracePeriodSeconds": 3.0,
            "connectionStatusMode": "list",
            "hiddenApps": [],
            "externalIPv6": false,
            "showDNSSwitcher": false,
            "customDNSPresets": Data(),
            "hiddenDNSPresets": [],
            "dnsPresetOrder": [],
            "useTouchID": true,
            "fritzBoxEnabled": false,
            "fritzBoxHost": "",
            "unifiEnabled": false,
            "unifiHost": "",
            "openWRTEnabled": false,
            "openWRTHost": "",
            "automaticUpdateChecksEnabled": true,
            "backgroundUpdateLastNotifiedVersion": ""
        ])
        let monitor = NetworkMonitor()
        self.monitor = monitor
        self.statusBar = StatusBarController(monitor: monitor)
        let updateNotifier = UpdateNotifier()
        self.updateNotifier = updateNotifier
        Task {
            await updateNotifier.start()
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncAutomaticUpdateChecks()
            }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    private func syncAutomaticUpdateChecks() {
        let enabled = UserDefaults.standard.bool(forKey: "automaticUpdateChecksEnabled")
        let updateNotifier = self.updateNotifier
        Task {
            await updateNotifier.setAutomaticChecksEnabled(enabled)
        }
    }
}
