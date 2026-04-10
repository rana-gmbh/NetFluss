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
import Network

final class SpeedTestResourceServer {
    private enum ServerError: LocalizedError {
        case missingPort
        case startupTimedOut

        var errorDescription: String? {
            switch self {
            case .missingPort:
                return "The local Speed Test server could not determine its listening port."
            case .startupTimedOut:
                return "The local Speed Test server did not become ready in time."
            }
        }
    }

    private let rootURL: URL
    private let queue = DispatchQueue(label: "com.local.netfluss.speedtest.server", qos: .utility)
    private var listener: NWListener?
    private var port: UInt16?

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    deinit {
        listener?.cancel()
    }

    func url(forRelativePath relativePath: String) throws -> URL {
        try startIfNeeded()
        guard let port else {
            throw ServerError.missingPort
        }
        return URL(string: "http://127.0.0.1:\(port)/\(relativePath)")!
    }

    private func startIfNeeded() throws {
        if port != nil {
            return
        }

        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                self?.port = listener?.port?.rawValue
                ready.signal()
            case .failed(let error):
                startupError = error
                ready.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 2) == .timedOut {
            listener.cancel()
            self.listener = nil
            throw ServerError.startupTimedOut
        }

        if let startupError {
            listener.cancel()
            self.listener = nil
            throw startupError
        }

        guard port != nil else {
            listener.cancel()
            self.listener = nil
            throw ServerError.missingPort
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulatedData: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var buffer = accumulatedData
            if let data {
                buffer.append(data)
            }

            if let requestEnd = buffer.range(of: Data([13, 10, 13, 10])) {
                self.respond(to: connection, requestData: buffer[..<requestEnd.lowerBound])
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receiveRequest(on: connection, accumulatedData: buffer)
        }
    }

    private func respond(to connection: NWConnection, requestData: Data.SubSequence) {
        guard
            let request = String(data: requestData, encoding: .utf8),
            let requestLine = request.components(separatedBy: "\r\n").first
        else {
            send(status: "400 Bad Request", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: "400 Bad Request", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        guard parts[0] == "GET" else {
            send(status: "405 Method Not Allowed", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        let target = String(parts[1])
        let relativePath = sanitizedRelativePath(from: target)
        let fileURL = rootURL.appendingPathComponent(relativePath, isDirectory: false)

        guard FileManager.default.fileExists(atPath: fileURL.path), let body = try? Data(contentsOf: fileURL) else {
            send(status: "404 Not Found", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        send(status: "200 OK", body: body, contentType: contentType(for: fileURL.pathExtension), on: connection)
    }

    private func sanitizedRelativePath(from requestTarget: String) -> String {
        let path = requestTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "/"
        let components = path.split(separator: "/").filter { component in
            !component.isEmpty && component != "." && component != ".."
        }

        if components.isEmpty {
            return "mlab.html"
        }

        return components.map(String.init).joined(separator: "/")
    }

    private func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html":
            return "text/html; charset=utf-8"
        case "js":
            return "application/javascript; charset=utf-8"
        case "json":
            return "application/json; charset=utf-8"
        default:
            return "application/octet-stream"
        }
    }

    private func send(status: String, body: Data, contentType: String, on connection: NWConnection) {
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Cache-Control: no-store\r\n"
        response += "Connection: close\r\n\r\n"

        var payload = Data(response.utf8)
        payload.append(body)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
