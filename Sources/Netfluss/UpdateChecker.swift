import Foundation

@MainActor
final class UpdateChecker: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.checking, .checking), (.upToDate, .upToDate): return true
            case (.available(let a), .available(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    struct AvailableUpdate: Equatable {
        let version: String
        let releaseNotes: String
        let releasePageURL: URL
        let downloadURL: URL?
    }

    @Published var state: State = .idle

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    func check() {
        Task { await performCheck() }
    }

    private func performCheck() async {
        state = .checking
        do {
            let url = URL(string: "https://api.github.com/repos/rana-gmbh/netfluss/releases/latest")!
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Netfluss/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            if isNewer(latest, than: currentVersion) {
                let downloadURL = release.assets
                    .first(where: { $0.name.hasSuffix(".zip") })
                    .flatMap { URL(string: $0.browserDownloadURL) }
                state = .available(AvailableUpdate(
                    version: latest,
                    releaseNotes: release.body ?? "",
                    releasePageURL: URL(string: release.htmlURL)!,
                    downloadURL: downloadURL
                ))
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func isNewer(_ latest: String, than current: String) -> Bool {
        let lp = latest.split(separator: ".").compactMap { Int($0) }
        let cp = current.split(separator: ".").compactMap { Int($0) }
        let len = max(lp.count, cp.count)
        let l = lp + Array(repeating: 0, count: len - lp.count)
        let c = cp + Array(repeating: 0, count: len - cp.count)
        for (a, b) in zip(l, c) {
            if a > b { return true }
            if a < b { return false }
        }
        return false
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
