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

struct AvailableUpdate: Equatable, Sendable {
    let version: String
    let releaseNotes: String
    let releasePageURL: URL
    let downloadURL: URL?
}

enum UpdateLookup {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/rana-gmbh/NetFluss/releases/latest")!

    static func currentVersion(bundle: Bundle = .main) -> String {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static func fetchLatestUpdate(currentVersion: String = currentVersion()) async throws -> AvailableUpdate? {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NetFluss/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response)

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        guard isNewer(latestVersion, than: currentVersion) else { return nil }

        let downloadURL = release.assets
            .first(where: { $0.name.hasSuffix(".zip") })
            .flatMap { URL(string: $0.browserDownloadURL) }

        return AvailableUpdate(
            version: latestVersion,
            releaseNotes: release.body ?? "",
            releasePageURL: URL(string: release.htmlURL)!,
            downloadURL: downloadURL
        )
    }

    private static func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateLookupError.invalidResponse(httpResponse.statusCode)
        }
    }

    static func isNewer(_ latest: String, than current: String) -> Bool {
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        let length = max(latestParts.count, currentParts.count)
        let paddedLatest = latestParts + Array(repeating: 0, count: length - latestParts.count)
        let paddedCurrent = currentParts + Array(repeating: 0, count: length - currentParts.count)

        for (latestValue, currentValue) in zip(paddedLatest, paddedCurrent) {
            if latestValue > currentValue { return true }
            if latestValue < currentValue { return false }
        }
        return false
    }
}

enum UpdateLookupError: LocalizedError {
    case invalidResponse(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let statusCode):
            return "GitHub returned HTTP \(statusCode)."
        }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case failed(String)
    }

    @Published var state: State = .idle

    let currentVersion: String

    init(currentVersion: String = UpdateLookup.currentVersion()) {
        self.currentVersion = currentVersion
    }

    func check() {
        Task { await performCheck() }
    }

    func performCheck() async {
        state = .checking
        do {
            if let update = try await UpdateLookup.fetchLatestUpdate(currentVersion: currentVersion) {
                state = .available(update)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

// MARK: - GitHub API model

private struct GitHubRelease: Decodable {
    let tagName: String
    let body: String?
    let htmlURL: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlURL = "html_url"
        case assets
    }
}
