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

enum SpeedTestProvider: String, CaseIterable, Identifiable, Sendable, Codable {
    case mlab
    case cloudflare

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mlab:
            return "M-Lab"
        case .cloudflare:
            return "Cloudflare"
        }
    }

    var preferenceLabel: String {
        switch self {
        case .mlab:
            return "M-Lab (Recommended)"
        case .cloudflare:
            return "Cloudflare"
        }
    }

    var shortDescription: String {
        switch self {
        case .mlab:
            return "Public measurement servers with a more Internet-path-oriented result."
        case .cloudflare:
            return "Nearby Cloudflare edge locations for a fast CDN-oriented result."
        }
    }

    var runtimeDescription: String {
        switch self {
        case .mlab:
            return "M-Lab chooses a nearby public measurement server and runs a full ndt7 download and upload test."
        case .cloudflare:
            return "Cloudflare measures against its nearest edge, which can be faster than broader Internet-path tests."
        }
    }
}

enum SpeedTestPhase: Equatable, Sendable {
    case idle
    case consentRequired
    case preparing
    case discoveringServer
    case testingLatency
    case testingDownload
    case testingUpload
    case finalizing
    case completed
    case cancelled
    case failed

    var title: String {
        switch self {
        case .idle:
            return "Ready"
        case .consentRequired:
            return "Consent required"
        case .preparing:
            return "Preparing"
        case .discoveringServer:
            return "Finding server"
        case .testingLatency:
            return "Measuring latency"
        case .testingDownload:
            return "Testing download"
        case .testingUpload:
            return "Testing upload"
        case .finalizing:
            return "Finalizing"
        case .completed:
            return "Complete"
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        }
    }

    var isRunning: Bool {
        switch self {
        case .preparing, .discoveringServer, .testingLatency, .testingDownload, .testingUpload, .finalizing:
            return true
        default:
            return false
        }
    }
}

struct SpeedTestResult: Equatable, Sendable, Codable, Identifiable {
    let id: UUID
    let provider: SpeedTestProvider
    let startedAt: Date
    let finishedAt: Date
    let downloadMbps: Double?
    let uploadMbps: Double?
    let latencyMs: Double?
    let jitterMs: Double?
    let serverName: String?
    let serverLocation: String?
    var note: String?

    init(
        id: UUID = UUID(),
        provider: SpeedTestProvider,
        startedAt: Date,
        finishedAt: Date,
        downloadMbps: Double?,
        uploadMbps: Double?,
        latencyMs: Double?,
        jitterMs: Double?,
        serverName: String?,
        serverLocation: String?,
        note: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.latencyMs = latencyMs
        self.jitterMs = jitterMs
        self.serverName = serverName
        self.serverLocation = serverLocation
        self.note = note
    }
}
