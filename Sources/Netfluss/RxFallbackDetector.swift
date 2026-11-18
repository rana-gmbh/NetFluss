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

/// Decides per adapter whether the kernel's inbound byte counter can be trusted
/// (macOS 26.5 froze `ifi_ibytes` on the primary NIC, issues #31/#45).
///
/// An adapter is flagged once its rx counter has not moved for `stuckThreshold`
/// while a meaningful amount of tx accrued. Requiring real tx volume keeps a
/// connected-but-idle secondary adapter (ARP/mDNS chatter only) from being
/// flagged and handed another adapter's download (issue #45).
///
/// The flag used to stick until NetFluss quit, so one false detection kept the
/// fallback running for the rest of the session. It now clears once the counter
/// moves again on `recoveryTicks` consecutive ticks.
struct RxFallbackDetector {
    enum Event: Equatable {
        case latched(String)
        case recovered(String)
    }

    static let stuckThreshold: TimeInterval = 20
    static let minActiveTxBytes: UInt64 = 128 * 1024
    static let recoveryTicks = 3

    private(set) var broken: Set<String> = []
    private var lastRx: [String: UInt64] = [:]
    private var lastRxChange: [String: Date] = [:]
    /// tx byte count captured when rx last moved, to measure the tx volume
    /// accrued while rx stayed frozen.
    private var txAtLastRxChange: [String: UInt64] = [:]
    private var movingTicks: [String: Int] = [:]

    /// Feeds one tick's counters for an up Wi-Fi/Ethernet adapter. `force`
    /// (the `NetfluseForceRxFallback` debug default) flags at once and never
    /// recovers.
    mutating func observe(id: String, rxBytes: UInt64, txBytes: UInt64, at now: Date, force: Bool = false) -> Event? {
        let previous = lastRx[id]
        let moved = previous != nil && rxBytes != previous
        if previous == nil || moved {
            // First observation counts as movement so the clock starts now.
            lastRxChange[id] = now
            lastRx[id] = rxBytes
            txAtLastRxChange[id] = txBytes
        }

        if broken.contains(id) {
            guard !force else { return nil }
            let ticks = moved ? (movingTicks[id] ?? 0) + 1 : 0
            movingTicks[id] = ticks
            guard ticks >= Self.recoveryTicks else { return nil }
            broken.remove(id)
            movingTicks[id] = nil
            return .recovered(id)
        }

        if force {
            return latch(id)
        }

        let txSinceStuck = txBytes &- (txAtLastRxChange[id] ?? txBytes)
        if let changed = lastRxChange[id],
           now.timeIntervalSince(changed) >= Self.stuckThreshold,
           txSinceStuck >= Self.minActiveTxBytes {
            return latch(id)
        }
        return nil
    }

    /// Restarts the clocks without forgetting which adapters are flagged.
    /// Kernel counters can jump across sleep, which must not read as movement
    /// or as staleness.
    mutating func resetClocks() {
        lastRx = [:]
        lastRxChange = [:]
        txAtLastRxChange = [:]
        movingTicks = [:]
    }

    private mutating func latch(_ id: String) -> Event {
        broken.insert(id)
        movingTicks[id] = 0
        return .latched(id)
    }
}
