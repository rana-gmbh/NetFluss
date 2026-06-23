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
import Darwin

/// Speaks the OpenVPN management interface protocol over the unix-domain socket
/// the (root) `openvpn` process listens on. The app drives the connection from
/// here without privilege: release the `--management-hold`, answer credential
/// prompts, observe state/byte-count events, and request a clean shutdown — all
/// via text commands on the socket.
///
/// openvpn was started with `--management-client-user <app-user>`, so the socket
/// is owned by the user and only this app can connect to it.
final class OpenVPNManagementClient {
    enum Event: Sendable {
        /// An OpenVPN state transition (e.g. "CONNECTING", "CONNECTED",
        /// "RECONNECTING", "EXITING"); `assignedIP` is set on CONNECTED.
        case state(String, assignedIP: String?)
        case byteCount(inBytes: UInt64, outBytes: UInt64)
        /// openvpn needs credentials of the given kind ("Auth", "Private Key").
        case needCredentials(kind: String)
        case authFailed(String)
        case log(String)
        case disconnected
    }

    /// Delivered on the client's internal queue.
    var onEvent: ((Event) -> Void)?
    /// Asked when openvpn prompts for credentials of a given kind; return nil to
    /// surface a `.needCredentials` event instead (e.g. cert-only profiles
    /// never prompt, so this can stay unset).
    var credentialsProvider: ((_ kind: String) -> (username: String?, password: String?)?)?

    private let socketPath: String
    private let queue = DispatchQueue(label: "com.local.netfluss.ovpn.mgmt")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var connectAttempts = 0
    private var holdReleased = false
    private static let maxConnectAttempts = 25   // ~5 s at 200 ms

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func connect() {
        queue.async { [weak self] in self?.attemptConnectLocked() }
    }

    /// Ask openvpn to exit cleanly (no root needed — it's a management command).
    func disconnect() {
        queue.async { [weak self] in
            self?.sendLocked("signal SIGTERM")
        }
    }

    func close() {
        queue.async { [weak self] in self?.teardownLocked() }
    }

    // MARK: - Connect (with retry until openvpn creates the socket)

    private func attemptConnectLocked() {
        guard fd < 0 else { return }
        connectAttempts += 1

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { retryOrFailLocked(); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(sock); emit(.authFailed("Management socket path too long.")); return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: pathBytes.count)
                }
            }
        }

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            Darwin.close(sock)
            retryOrFailLocked()
            return
        }

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        fd = sock

        let rs = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        rs.setEventHandler { [weak self] in self?.drainLocked() }
        rs.resume()
        readSource = rs

        // Enable notifications and release the hold so openvpn proceeds.
        sendLocked("state on")
        sendLocked("bytecount 2")
        releaseHoldLocked()
    }

    private func releaseHoldLocked() {
        guard !holdReleased else { return }
        holdReleased = true
        sendLocked("hold release")
    }

    private func retryOrFailLocked() {
        guard connectAttempts < Self.maxConnectAttempts else {
            emit(.authFailed("Could not reach the OpenVPN management interface."))
            return
        }
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.attemptConnectLocked() }
    }

    // MARK: - Receive / parse

    private func drainLocked() {
        guard fd >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                teardownLocked(); emit(.disconnected); return
            } else {
                break   // EAGAIN
            }
        }

        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard var line = String(data: lineData, encoding: .utf8) else { continue }
            if line.hasSuffix("\r") { line.removeLast() }
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        if line.hasPrefix(">STATE:") {
            // >STATE:<time>,<state>,<desc>,<localIP>,<remoteIP>,...
            let fields = line.dropFirst(">STATE:".count).split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return }
            let state = String(fields[1])
            let ip = fields.count >= 4 && !fields[3].isEmpty ? String(fields[3]) : nil
            emit(.state(state, assignedIP: ip))
        } else if line.hasPrefix(">BYTECOUNT:") {
            let parts = line.dropFirst(">BYTECOUNT:".count).split(separator: ",")
            if parts.count == 2, let inB = UInt64(parts[0]), let outB = UInt64(parts[1]) {
                emit(.byteCount(inBytes: inB, outBytes: outB))
            }
        } else if line.hasPrefix(">PASSWORD:") {
            handlePasswordPrompt(String(line.dropFirst(">PASSWORD:".count)))
        } else if line.hasPrefix(">LOG:") {
            let parts = line.dropFirst(">LOG:".count).split(separator: ",", maxSplits: 2)
            emit(.log(parts.count == 3 ? String(parts[2]) : line))
        } else if line.hasPrefix(">HOLD:") {
            releaseHoldLocked()
        }
        // SUCCESS:/ERROR:/>INFO: command replies and greeting are ignored.
    }

    private func handlePasswordPrompt(_ body: String) {
        if body.hasPrefix("Verification Failed") {
            emit(.authFailed(body))
            return
        }
        // body like: Need 'Auth' username/password   OR   Need 'Private Key' password
        guard let first = body.firstIndex(of: "'"),
              let second = body[body.index(after: first)...].firstIndex(of: "'") else { return }
        let kind = String(body[body.index(after: first)..<second])

        guard let creds = credentialsProvider?(kind), creds.username != nil || creds.password != nil else {
            emit(.needCredentials(kind: kind))
            return
        }
        if let user = creds.username {
            sendLocked("username \"\(Self.escape(kind))\" \"\(Self.escape(user))\"")
        }
        if let password = creds.password {
            sendLocked("password \"\(Self.escape(kind))\" \"\(Self.escape(password))\"")
        }
    }

    // MARK: - Send

    func sendCredentials(kind: String, username: String?, password: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            if let username { self.sendLocked("username \"\(Self.escape(kind))\" \"\(Self.escape(username))\"") }
            if let password { self.sendLocked("password \"\(Self.escape(kind))\" \"\(Self.escape(password))\"") }
        }
    }

    private func sendLocked(_ command: String) {
        guard fd >= 0 else { return }
        let data = Array((command + "\n").utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    }

    private func teardownLocked() {
        readSource?.cancel(); readSource = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        buffer.removeAll(keepingCapacity: false)
        holdReleased = false
    }

    private func emit(_ event: Event) {
        onEvent?(event)
    }

    /// Escape backslashes and double-quotes for the management command grammar.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
