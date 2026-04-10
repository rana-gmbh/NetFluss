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

@MainActor
final class AppIconController {
    static let shared = AppIconController()

    private var themeObserverInstalled = false

    func start() {
        guard !themeObserverInstalled else {
            updateIcon()
            return
        }

        themeObserverInstalled = true
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceDidChange(_:)),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        updateIcon()
    }

    deinit {
        if themeObserverInstalled {
            DistributedNotificationCenter.default().removeObserver(self)
        }
    }

    @objc private func systemAppearanceDidChange(_ notification: Notification) {
        updateIcon()
    }

    func updateIcon() {
        guard let icon = preferredIconImage() else { return }
        NSApp.applicationIconImage = icon
    }

    private func preferredIconImage() -> NSImage? {
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let candidates = isDarkMode ? darkIconCandidates() + lightIconCandidates() : lightIconCandidates() + darkIconCandidates()

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }

        return nil
    }

    private func darkIconCandidates() -> [URL] {
        resourceCandidates(named: "AppIconDark.icns", fallbackRelativePaths: [
            "Packaging/Resources/AppIconDark.icns",
            "Icon.Pack/Dark.icns"
        ])
    }

    private func lightIconCandidates() -> [URL] {
        resourceCandidates(named: "AppIcon.icns", fallbackRelativePaths: [
            "Packaging/Resources/AppIcon.icns",
            "Icon.Pack/Light.icns"
        ])
    }

    private func resourceCandidates(named resourceName: String, fallbackRelativePaths: [String]) -> [URL] {
        var urls: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(resourceName, isDirectory: false))
        }

        if let bundleURL = Bundle.main.bundleURL as URL? {
            urls.append(bundleURL.appendingPathComponent("Contents/Resources/\(resourceName)", isDirectory: false))
        }

        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        urls.append(contentsOf: fallbackRelativePaths.map { workingDirectory.appendingPathComponent($0, isDirectory: false) })

        return urls
    }
}
