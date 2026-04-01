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
import Foundation

actor UpdateNotifier {
    private enum DefaultsKey {
        static let lastCheckDate = "backgroundUpdateLastCheckDate"
        static let lastNotifiedVersion = "backgroundUpdateLastNotifiedVersion"
        static let automaticChecksEnabled = "automaticUpdateChecksEnabled"
    }

    private let defaults: UserDefaults
    private let currentVersion: String
    private let checkInterval: TimeInterval
    private var schedulerTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        currentVersion: String = UpdateLookup.currentVersion(),
        checkInterval: TimeInterval = 24 * 60 * 60
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.checkInterval = checkInterval
    }

    deinit {
        schedulerTask?.cancel()
    }

    func start() {
        setAutomaticChecksEnabled(defaults.bool(forKey: DefaultsKey.automaticChecksEnabled))
    }

    func stop() {
        schedulerTask?.cancel()
        schedulerTask = nil
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        if enabled {
            guard schedulerTask == nil else { return }
            schedulerTask = Task { [weak self] in
                await self?.runScheduler()
            }
        } else {
            stop()
        }
    }

    private func runScheduler() async {
        while !Task.isCancelled {
            let delay = nextCheckDelay()
            if delay > 0 {
                let nanoseconds = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled else { return }
            await performScheduledCheck()
        }
    }

    private func nextCheckDelay(now: Date = Date()) -> TimeInterval {
        guard let lastCheckDate = defaults.object(forKey: DefaultsKey.lastCheckDate) as? Date else {
            return 0
        }
        let nextCheckDate = lastCheckDate.addingTimeInterval(checkInterval)
        return max(0, nextCheckDate.timeIntervalSince(now))
    }

    private func performScheduledCheck(now: Date = Date()) async {
        defaults.set(now, forKey: DefaultsKey.lastCheckDate)

        do {
            guard let update = try await UpdateLookup.fetchLatestUpdate(currentVersion: currentVersion) else { return }
            guard shouldNotify(for: update) else { return }

            await MainActor.run {
                UpdateAlertPresenter.present(update: update)
            }
            defaults.set(update.version, forKey: DefaultsKey.lastNotifiedVersion)
        } catch {
            // Keep background checks silent; the About window exposes manual errors.
        }
    }

    private func shouldNotify(for update: AvailableUpdate) -> Bool {
        defaults.string(forKey: DefaultsKey.lastNotifiedVersion) != update.version
    }
}

@MainActor
private enum UpdateAlertPresenter {
    static func present(update: AvailableUpdate) {
        UpdateNotificationWindowController.shared.show(update: update)
    }
}
