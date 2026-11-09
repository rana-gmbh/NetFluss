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
import ServiceManagement

/// What the Launch at login toggle should show (issue #67).
///
/// SMAppService has four states, and collapsing them to "enabled or not" is
/// what made the toggle look broken: a user who had switched NetFluss off in
/// System Settings, or who ran it from Downloads, clicked the switch and
/// watched it flip straight back with no explanation.
enum LaunchAtLoginState: Equatable {
    case on
    /// Registered, but macOS is waiting for the user to allow it under
    /// Login Items. It will not ask again by itself.
    case needsApproval
    case off
    /// macOS cannot register this copy at all — in practice because it is
    /// running translocated, straight out of Downloads or a disk image.
    case unavailable

    /// The switch shows the user's intent: once registered, it stays on while
    /// approval is pending, with a note saying what is still needed.
    var isOn: Bool { self == .on || self == .needsApproval }
}

enum LaunchAtLogin {
    /// Gatekeeper runs a quarantined app that was never moved from a randomised,
    /// read-only path, and login item registration fails from there.
    static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    static var currentState: LaunchAtLoginState {
        state(for: SMAppService.mainApp.status, translocated: isTranslocated)
    }

    nonisolated static func state(for status: SMAppService.Status, translocated: Bool) -> LaunchAtLoginState {
        if translocated { return .unavailable }
        switch status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notFound: return .unavailable
        case .notRegistered: return .off
        @unknown default: return .off
        }
    }

    /// Register or unregister, returning a message only when there is
    /// something the user can act on that the state note does not already say.
    @discardableResult
    static func set(enabled: Bool) -> (state: LaunchAtLoginState, error: String?) {
        var failure: Error?
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            failure = error
        }

        let state = currentState
        // A denied login item throws *and* lands in .requiresApproval; the
        // approval note is the actionable version of that error, so the raw
        // message would only repeat it less helpfully.
        guard let failure, state != .needsApproval, state != .unavailable else {
            return (state, nil)
        }
        return (state, failure.localizedDescription)
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
