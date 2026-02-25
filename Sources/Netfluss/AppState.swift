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
final class AppState: ObservableObject {
    let monitor: NetworkMonitor
    let statusBar: StatusBarController

    init() {
        UserDefaults.standard.register(defaults: [
            "refreshInterval": 1.0,
            "showInactive": false,
            "showOtherAdapters": false,
            "useBits": false,
            "hiddenAdapters": [],
            "showTopApps": false,
            "uploadColor": "green",
            "downloadColor": "blue",
            "theme": "system",
            "menuBarFontSize": 10.0,
            "menuBarFontDesign": "monospaced",
            "adapterOrder": [],
            "adapterCustomNames": Data(),
            "menuBarMode": "rates",
            "totalsOnlyVisibleAdapters": false
        ])
        let monitor = NetworkMonitor()
        self.monitor = monitor
        self.statusBar = StatusBarController(monitor: monitor)
    }
}
