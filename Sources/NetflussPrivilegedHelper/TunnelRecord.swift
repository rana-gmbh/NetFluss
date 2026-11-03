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

/// What the helper writes down about each tunnel it starts, so a helper that
/// restarted (an app update re-registers it, or it crashed) can still find and
/// stop them. Its in-memory map dies with it; before these records, a tunnel
/// started by the previous helper could no longer be stopped by anyone and
/// stayed up as an unexplained utun (issue #68).
///
/// Records live in the helper's root-only stage folder, next to the configs.
struct TunnelRecord: Codable, Equatable {
    enum Kind: String, Codable {
        case openVPN
        case wireGuard
    }

    var kind: Kind
    /// OpenVPN: the process id. WireGuard: the utun interface.
    var handle: String
    var owner: String
    /// OpenVPN: the process's start time, so a reused pid is never mistaken
    /// for the tunnel.
    var startTime: UInt64?
    /// OpenVPN: the staged profile folder. WireGuard: the staged config.
    var stagedPath: String

    static let filePrefix = "tunnel-"
    static let fileSuffix = ".json"

    /// Handles are digits (pid) or an interface name; anything else would let a
    /// handle walk out of the record folder.
    static func isValidHandle(_ handle: String) -> Bool {
        !handle.isEmpty && handle.count <= 16
            && handle.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
    }

    static func fileName(for handle: String) -> String? {
        isValidHandle(handle) ? filePrefix + handle + fileSuffix : nil
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> TunnelRecord? {
        guard let record = try? JSONDecoder().decode(TunnelRecord.self, from: data),
              isValidHandle(record.handle) else { return nil }
        return record
    }

    /// Whether a live process is the openvpn this record describes: same start
    /// time and the bundled binary's name. Only then may it be signalled.
    func describesOpenVPN(processPath: String?, startTime: UInt64?) -> Bool {
        guard kind == .openVPN, let recorded = self.startTime, let startTime, recorded == startTime,
              let processPath else { return false }
        return (processPath as NSString).lastPathComponent == "openvpn"
            && processPath.contains("/Contents/Library/VPN/")
    }
}

/// Process facts the helper needs for records and for stopping by pid.
enum ProcessInfoLookup {
    static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
