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

/// Parses imported OpenVPN configs into a profile shape. Accepts a single
/// `.ovpn`, a folder of them, or a `.zip` (how providers usually ship "router"
/// profiles — one file per server). Each `.ovpn` becomes one selectable server.
enum VPNConfigImporter {
    struct ConfigFile {
        let name: String
        let data: Data
    }

    struct OpenVPNImport {
        var suggestedName: String
        var files: [ConfigFile]
        var endpoints: [VPNServerEndpoint]
        var primaryFileName: String
        var requiresCredentials: Bool
    }

    enum ImportError: LocalizedError {
        case noConfigsFound
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noConfigsFound: return "No .ovpn configuration files were found."
            case .unreadable(let detail): return "Could not read the configuration: \(detail)."
            }
        }
    }

    static func importOpenVPN(from url: URL) throws -> OpenVPNImport {
        let ovpnURLs = try collectOVPNFiles(from: url)
        guard !ovpnURLs.isEmpty else { throw ImportError.noConfigsFound }

        var files: [ConfigFile] = []
        var endpoints: [VPNServerEndpoint] = []
        var requiresCredentials = false
        var usedNames = Set<String>()

        for fileURL in ovpnURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else { continue }

            // Ensure a unique stored filename across the bundle.
            var name = fileURL.lastPathComponent
            var n = 1
            while usedNames.contains(name) { name = "\(fileURL.deletingPathExtension().lastPathComponent)-\(n).ovpn"; n += 1 }
            usedNames.insert(name)
            files.append(ConfigFile(name: name, data: data))

            let parsed = parse(text)
            requiresCredentials = requiresCredentials || parsed.requiresCredentials
            endpoints.append(
                VPNServerEndpoint(
                    label: fileURL.deletingPathExtension().lastPathComponent,
                    host: parsed.host ?? fileURL.deletingPathExtension().lastPathComponent,
                    port: parsed.port,
                    transport: parsed.transport,
                    configFileName: name
                )
            )
        }

        guard let primary = files.first else { throw ImportError.noConfigsFound }
        let suggestedName = ovpnURLs.count == 1
            ? url.deletingPathExtension().lastPathComponent
            : url.deletingPathExtension().lastPathComponent

        return OpenVPNImport(
            suggestedName: suggestedName,
            files: files,
            endpoints: endpoints,
            primaryFileName: primary.name,
            requiresCredentials: requiresCredentials
        )
    }

    // MARK: - Parsing

    private static func parse(_ text: String) -> (host: String?, port: Int?, transport: String?, requiresCredentials: Bool) {
        var firstRemoteHost: String?
        var remotePort: Int?
        var remoteProto: String?
        var globalPort: Int?
        var globalProto: String?
        var requiresCredentials = false

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let directive = tokens.first else { continue }

            switch directive {
            case "remote" where firstRemoteHost == nil:
                if tokens.count >= 2 { firstRemoteHost = tokens[1] }
                if tokens.count >= 3 { remotePort = Int(tokens[2]) }
                if tokens.count >= 4 { remoteProto = normalizeProto(tokens[3]) }
            case "port":
                if tokens.count >= 2 { globalPort = Int(tokens[1]) }
            case "proto":
                if tokens.count >= 2 { globalProto = normalizeProto(tokens[1]) }
            case "auth-user-pass":
                // Bare directive prompts interactively; with a file arg it reads
                // from disk (not imported here, but still treat as needing creds).
                requiresCredentials = true
            default:
                break
            }
        }

        return (
            host: firstRemoteHost,
            port: remotePort ?? globalPort,
            transport: remoteProto ?? globalProto,
            requiresCredentials: requiresCredentials
        )
    }

    private static func normalizeProto(_ proto: String) -> String {
        let p = proto.lowercased()
        if p.hasPrefix("tcp") { return "tcp" }
        if p.hasPrefix("udp") { return "udp" }
        return p
    }

    // MARK: - Source collection

    private static func collectOVPNFiles(from url: URL) throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }

        if url.pathExtension.lowercased() == "ovpn" {
            return [url]
        }

        let searchRoot: URL
        if url.pathExtension.lowercased() == "zip" {
            searchRoot = try extractZip(url)
        } else if isDir.boolValue {
            searchRoot = url
        } else {
            // Unknown single file — try treating it as a config regardless.
            return [url]
        }

        guard let enumerator = fm.enumerator(at: searchRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "ovpn" }
    }

    private static func extractZip(_ zipURL: URL) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("netfluss-vpn-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, dest.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ImportError.unreadable("could not extract \(zipURL.lastPathComponent)")
        }
        return dest
    }
}
