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

/// The part of `NetworkMonitor` Preferences actually shows.
///
/// `NetworkMonitor` publishes on every tick, because the rates change, and any
/// view observing it is rebuilt each time. PreferencesView is one very large
/// view, so that meant rebuilding the whole window once a second while someone
/// was typing in it. This republishes only when something it shows has changed.
@MainActor
final class PreferencesNetworkState: ObservableObject {
    @Published private(set) var gatewayIP: String
    @Published private(set) var adapters: [AdapterStatus]
    @Published private(set) var recentAppNames: [String]
    @Published private(set) var dnsAutoSwitchState: DNSAutoSwitchState
    @Published private(set) var fritzBoxError: String?
    @Published private(set) var unifiError: String?
    @Published private(set) var openWRTError: String?
    @Published private(set) var opnsenseError: String?

    init(monitor: NetworkMonitor) {
        gatewayIP = monitor.gatewayIP
        adapters = monitor.adapters.map(\.withoutTraffic)
        recentAppNames = monitor.recentAppNames
        dnsAutoSwitchState = monitor.dnsAutoSwitchState
        fritzBoxError = monitor.fritzBoxError
        unifiError = monitor.unifiError
        openWRTError = monitor.openWRTError
        opnsenseError = monitor.opnsenseError

        monitor.$gatewayIP.removeDuplicates().assign(to: &$gatewayIP)
        monitor.$adapters.map { $0.map(\.withoutTraffic) }.removeDuplicates().assign(to: &$adapters)
        monitor.$recentAppNames.removeDuplicates().assign(to: &$recentAppNames)
        monitor.$dnsAutoSwitchState.removeDuplicates().assign(to: &$dnsAutoSwitchState)
        monitor.$fritzBoxError.removeDuplicates().assign(to: &$fritzBoxError)
        monitor.$unifiError.removeDuplicates().assign(to: &$unifiError)
        monitor.$openWRTError.removeDuplicates().assign(to: &$openWRTError)
        monitor.$opnsenseError.removeDuplicates().assign(to: &$opnsenseError)
    }
}
