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

/// One live connection as the Clash API reports it (issue #61).
struct ClashConnection: Equatable, Sendable {
    let id: String
    /// The outbound that actually egresses — `chains[0]`, see `ClashConnectionsSnapshot`.
    let node: String
    /// Cumulative bytes for *this connection*, not for the node.
    let uploadBytes: UInt64
    let downloadBytes: UInt64
    let host: String
    let network: String
    let processPath: String
}

/// A `GET /connections` snapshot.
///
/// `uploadTotal` / `downloadTotal` are process-wide monotonic counters; the
/// per-connection counters only cover connections that are still open, so the
/// two disagree by whatever closed since the last poll. `ClashNodeAccumulator`
/// uses the difference to account for the remainder instead of losing it.
struct ClashConnectionsSnapshot: Equatable, Sendable {
    let uploadTotal: UInt64
    let downloadTotal: UInt64
    let connections: [ClashConnection]
}

enum ClashAPIError: Error, Equatable {
    case invalidURL
    /// 401/403 — wrong or missing `secret`.
    case authFailed
    case httpStatus(Int)
    /// Transport failure; carries the URLError so the UI can say why.
    case requestFailed(URLError?)
    case parseError
}

enum ClashAPIMonitor {
    /// The port every Clash-compatible client defaults to for `external-controller`.
    static let defaultPort = 9090

    // MARK: - Public API

    /// Fetch a connections snapshot. `secret` may be empty — sing-box only
    /// requires it when `experimental.clash_api.secret` is set.
    static func fetchConnections(host: String, secret: String) async throws -> ClashConnectionsSnapshot {
        let url = try connectionsURL(for: host)
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpMethod = "GET"
        request.setValue("NetFluss/1.0", forHTTPHeaderField: "User-Agent")
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw ClashAPIError.requestFailed(error)
        } catch {
            throw ClashAPIError.requestFailed(nil)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ClashAPIError.authFailed
            }
            throw ClashAPIError.httpStatus(http.statusCode)
        }

        return try parseSnapshot(data)
    }

    /// Reachability + auth check for the preferences pane's Test button.
    static func probe(host: String, secret: String) async throws {
        _ = try await fetchConnections(host: host, secret: secret)
    }

    // MARK: - URL handling

    /// Accepts "127.0.0.1:9090", "127.0.0.1", "http://host:9090" and
    /// "http://host:9090/" alike; the port defaults to 9090.
    static func connectionsURL(for host: String) throws -> URL {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClashAPIError.invalidURL }

        var components: URLComponents?
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            components = URLComponents(string: trimmed)
        } else {
            components = URLComponents(string: "http://\(trimmed)")
        }

        guard var parts = components, let parsedHost = parts.host, !parsedHost.isEmpty else {
            throw ClashAPIError.invalidURL
        }
        if parts.port == nil {
            parts.port = defaultPort
        }
        parts.path = "/connections"
        parts.query = nil
        parts.fragment = nil

        guard let url = parts.url else { throw ClashAPIError.invalidURL }
        return url
    }

    // MARK: - Parsing

    static func parseSnapshot(_ data: Data) throws -> ClashConnectionsSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClashAPIError.parseError
        }

        let uploadTotal = unsignedValue(root["uploadTotal"])
        let downloadTotal = unsignedValue(root["downloadTotal"])

        // A snapshot with no open connections is legitimate (an idle proxy), so
        // a missing array is only a parse error when the totals are missing too.
        guard let rawConnections = root["connections"] as? [[String: Any]] else {
            if root["uploadTotal"] == nil && root["downloadTotal"] == nil {
                throw ClashAPIError.parseError
            }
            return ClashConnectionsSnapshot(
                uploadTotal: uploadTotal,
                downloadTotal: downloadTotal,
                connections: []
            )
        }

        var connections: [ClashConnection] = []
        connections.reserveCapacity(rawConnections.count)

        for raw in rawConnections {
            guard let id = raw["id"] as? String, !id.isEmpty else { continue }
            let metadata = raw["metadata"] as? [String: Any] ?? [:]
            connections.append(
                ClashConnection(
                    id: id,
                    node: node(fromChains: raw["chains"]),
                    uploadBytes: unsignedValue(raw["upload"]),
                    downloadBytes: unsignedValue(raw["download"]),
                    host: (metadata["host"] as? String) ?? "",
                    network: (metadata["network"] as? String) ?? "",
                    processPath: (metadata["processPath"] as? String) ?? ""
                )
            )
        }

        return ClashConnectionsSnapshot(
            uploadTotal: uploadTotal,
            downloadTotal: downloadTotal,
            connections: connections
        )
    }

    /// sing-box builds the chain entry-first and then reverses it
    /// (`common/trafficcontrol/tracker.go`), so element 0 is the outbound that
    /// actually egresses and the last element is the selector or group that
    /// picked it. Grouping by the last element would bucket everything under
    /// one selector, which is exactly not what issue #61 asks for.
    static func node(fromChains chains: Any?) -> String {
        guard let chain = chains as? [String] else { return unknownNodeKey }
        guard let first = chain.first(where: { !$0.isEmpty }) else { return unknownNodeKey }
        return first
    }

    /// Key used when a connection carries no usable chain.
    static let unknownNodeKey = "—"

    private static func unsignedValue(_ value: Any?) -> UInt64 {
        switch value {
        case let number as NSNumber:
            let raw = number.int64Value
            return raw > 0 ? UInt64(raw) : 0
        case let string as String:
            return UInt64(string) ?? 0
        default:
            return 0
        }
    }
}

// MARK: - Per-node accounting

/// Turns successive `/connections` snapshots into per-node byte deltas.
///
/// Connections carry cumulative counters and vanish the moment they close, so a
/// snapshot diff alone silently loses everything a short-lived connection moved
/// between two polls — which matters when the figure is meant to track a paid
/// subscription quota. The process-wide totals *are* monotonic, so whatever the
/// per-connection deltas fail to explain is attributed to `unattributedKey`
/// rather than dropped.
struct ClashNodeAccumulator {
    /// Bucket for traffic the per-connection diff cannot attribute: connections
    /// that opened and closed inside one interval, plus the DNS connections
    /// sing-box filters out of the list but still counts in the totals.
    static let unattributedKey = "Unattributed"

    private struct Previous {
        let node: String
        let uploadBytes: UInt64
        let downloadBytes: UInt64
    }

    private var previous: [String: Previous] = [:]
    private var previousUploadTotal: UInt64?
    private var previousDownloadTotal: UInt64?

    /// Drop all carried state — used when the feature is switched off, the host
    /// changes, or a poll fails, so a gap is never billed to a node as one
    /// enormous delta.
    mutating func reset() {
        previous = [:]
        previousUploadTotal = nil
        previousDownloadTotal = nil
    }

    /// Per-node bytes transferred since the previous snapshot.
    ///
    /// The first snapshot after a reset establishes the baseline and yields
    /// nothing: its counters describe traffic from before NetFluss was looking.
    mutating func consume(_ snapshot: ClashConnectionsSnapshot) -> [StatisticsNodeDelta] {
        var current: [String: Previous] = [:]
        current.reserveCapacity(snapshot.connections.count)

        var uploadByNode: [String: UInt64] = [:]
        var downloadByNode: [String: UInt64] = [:]
        let isBaseline = previousUploadTotal == nil && previousDownloadTotal == nil

        // sing-box restarting resets the process-wide counters; treat a counter
        // that went backwards as a fresh baseline instead of underflowing.
        let restarted = (previousUploadTotal ?? 0) > snapshot.uploadTotal
            || (previousDownloadTotal ?? 0) > snapshot.downloadTotal

        for connection in snapshot.connections {
            current[connection.id] = Previous(
                node: connection.node,
                uploadBytes: connection.uploadBytes,
                downloadBytes: connection.downloadBytes
            )

            guard !isBaseline, !restarted else { continue }

            // A connection id we have seen before contributes its growth; a new
            // one contributes everything it has moved, since it opened after the
            // previous snapshot.
            let seen = previous[connection.id]
            let upload = connection.uploadBytes &- min(seen?.uploadBytes ?? 0, connection.uploadBytes)
            let download = connection.downloadBytes &- min(seen?.downloadBytes ?? 0, connection.downloadBytes)
            if upload > 0 {
                uploadByNode[connection.node, default: 0] += upload
            }
            if download > 0 {
                downloadByNode[connection.node, default: 0] += download
            }
        }

        var deltas: [StatisticsNodeDelta] = []

        if !isBaseline, !restarted,
           let previousUpload = previousUploadTotal,
           let previousDownload = previousDownloadTotal {
            let accountedUpload = uploadByNode.values.reduce(0, +)
            let accountedDownload = downloadByNode.values.reduce(0, +)
            let totalUpload = snapshot.uploadTotal - min(previousUpload, snapshot.uploadTotal)
            let totalDownload = snapshot.downloadTotal - min(previousDownload, snapshot.downloadTotal)
            let missingUpload = totalUpload > accountedUpload ? totalUpload - accountedUpload : 0
            let missingDownload = totalDownload > accountedDownload ? totalDownload - accountedDownload : 0
            if missingUpload > 0 || missingDownload > 0 {
                deltas.append(
                    StatisticsNodeDelta(
                        name: Self.unattributedKey,
                        downloadBytes: missingDownload,
                        uploadBytes: missingUpload
                    )
                )
            }
        }

        for node in Set(uploadByNode.keys).union(downloadByNode.keys) {
            deltas.append(
                StatisticsNodeDelta(
                    name: node,
                    downloadBytes: downloadByNode[node] ?? 0,
                    uploadBytes: uploadByNode[node] ?? 0
                )
            )
        }

        previous = current
        previousUploadTotal = snapshot.uploadTotal
        previousDownloadTotal = snapshot.downloadTotal
        return deltas
    }
}
