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

/// Parses imported VPN configs into a profile shape. Accepts a single config, a
/// folder of them, or a `.zip` (how providers usually ship "router" profiles —
/// one file per server). Each config file becomes one selectable server.
///
/// OpenVPN configs that reference external files (`ca ca.crt`, `tls-auth ta.key`)
/// have those sidecar files imported too; folder/zip imports copy the whole tree.
/// WireGuard `.conf` files are self-contained.
enum VPNConfigImporter {
    struct ConfigFile {
        /// Path relative to the profile directory (may contain subdirectories).
        let name: String
        let data: Data
    }

    struct ImportResult {
        var suggestedName: String
        var files: [ConfigFile]
        var endpoints: [VPNServerEndpoint]
        var primaryFileName: String
        var requiresCredentials: Bool
    }

    enum ImportError: LocalizedError {
        case noConfigsFound(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noConfigsFound(let ext): return "No .\(ext) configuration files were found."
            case .unreadable(let detail): return "Could not read the configuration: \(detail)."
            }
        }
    }

    private struct Parsed {
        var host: String?
        var port: Int?
        var transport: String?
        var requiresCredentials: Bool
    }

    private static let maxFileBytes = 5 * 1024 * 1024

    // MARK: - Entry points

    static func importOpenVPN(from url: URL) throws -> ImportResult {
        try importConfigs(from: url, ext: "ovpn", collectSidecars: true, parse: parseOpenVPN)
    }

    static func importWireGuard(from url: URL) throws -> ImportResult {
        try importConfigs(from: url, ext: "conf", collectSidecars: false, parse: parseWireGuard)
    }

    // MARK: - Generic import

    private static func importConfigs(
        from url: URL,
        ext: String,
        collectSidecars: Bool,
        parse: (String) -> Parsed
    ) throws -> ImportResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }

        if url.pathExtension.lowercased() == "zip" {
            return try importTree(root: try extractZip(url), ext: ext, suggestedName: url.deletingPathExtension().lastPathComponent, parse: parse)
        }
        if isDir.boolValue {
            return try importTree(root: url, ext: ext, suggestedName: url.lastPathComponent, parse: parse)
        }
        return try importSingle(url, collectSidecars: collectSidecars, parse: parse)
    }

    private static func importSingle(_ url: URL, collectSidecars: Bool, parse: (String) -> Parsed) throws -> ImportResult {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }
        let name = url.lastPathComponent
        var files = [ConfigFile(name: name, data: data)]

        if collectSidecars {
            let dir = url.deletingLastPathComponent()
            for ref in referencedFiles(in: text) where !ref.contains("..") {
                let refURL = dir.appendingPathComponent(ref)
                if let d = try? Data(contentsOf: refURL), d.count <= maxFileBytes {
                    files.append(ConfigFile(name: ref, data: d))
                }
            }
        }

        let parsed = parse(text)
        let baseName = url.deletingPathExtension().lastPathComponent
        let endpoint = VPNServerEndpoint(
            label: baseName, host: parsed.host ?? baseName, port: parsed.port,
            transport: parsed.transport, configFileName: name
        )
        return ImportResult(suggestedName: baseName, files: files, endpoints: [endpoint], primaryFileName: name, requiresCredentials: parsed.requiresCredentials)
    }

    private static func importTree(root: URL, ext: String, suggestedName: String, parse: (String) -> Parsed) throws -> ImportResult {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw ImportError.noConfigsFound(ext)
        }

        var files: [ConfigFile] = []
        var configRelPaths: [String] = []
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let rel = relativePath(of: fileURL, under: root)
            guard !rel.isEmpty, !rel.hasPrefix("__MACOSX/"), !fileURL.lastPathComponent.hasPrefix("._") else { continue }
            guard let data = try? Data(contentsOf: fileURL), data.count <= maxFileBytes else { continue }
            files.append(ConfigFile(name: rel, data: data))
            if fileURL.pathExtension.lowercased() == ext { configRelPaths.append(rel) }
        }
        guard !configRelPaths.isEmpty else { throw ImportError.noConfigsFound(ext) }

        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.data) })
        var endpoints: [VPNServerEndpoint] = []
        var requiresCredentials = false
        for rel in configRelPaths.sorted() {
            let text = byName[rel].flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let parsed = parse(text)
            requiresCredentials = requiresCredentials || parsed.requiresCredentials
            let label = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
            endpoints.append(
                VPNServerEndpoint(label: label, host: parsed.host ?? label, port: parsed.port, transport: parsed.transport, configFileName: rel)
            )
        }

        return ImportResult(suggestedName: suggestedName, files: files, endpoints: endpoints, primaryFileName: configRelPaths.sorted().first!, requiresCredentials: requiresCredentials)
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") { return String(path.dropFirst(rootPath.count + 1)) }
        return url.lastPathComponent
    }

    // MARK: - OpenVPN parsing

    private static let fileDirectives: Set<String> = [
        "ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2",
        "pkcs12", "crl-verify", "extra-certs", "dh"
    ]

    private static func referencedFiles(in text: String) -> [String] {
        var refs: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";"), !line.hasPrefix("<") else { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let directive = tokens.first, fileDirectives.contains(directive), tokens.count >= 2 else { continue }
            let ref = tokens[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !ref.isEmpty, ref != "[inline]", ref.lowercased() != "none" else { continue }
            refs.append(ref)
        }
        return refs
    }

    private static func parseOpenVPN(_ text: String) -> Parsed {
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
                requiresCredentials = true
            default:
                break
            }
        }
        return Parsed(host: firstRemoteHost, port: remotePort ?? globalPort, transport: remoteProto ?? globalProto, requiresCredentials: requiresCredentials)
    }

    private static func normalizeProto(_ proto: String) -> String {
        let p = proto.lowercased()
        if p.hasPrefix("tcp") { return "tcp" }
        if p.hasPrefix("udp") { return "udp" }
        return p
    }

    // MARK: - WireGuard parsing

    private static func parseWireGuard(_ text: String) -> Parsed {
        var host: String?
        var port: Int?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("[") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0].caseInsensitiveCompare("Endpoint") == .orderedSame {
                let endpoint = parts[1]
                // host:port — host may be a bracketed IPv6 literal.
                if endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") {
                    host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
                    if let colon = endpoint[close...].lastIndex(of: ":") {
                        port = Int(endpoint[endpoint.index(after: colon)...])
                    }
                } else if let colon = endpoint.lastIndex(of: ":") {
                    host = String(endpoint[..<colon])
                    port = Int(endpoint[endpoint.index(after: colon)...])
                } else {
                    host = endpoint
                }
            }
        }
        // WireGuard is always UDP; keys (not user/pass) handle auth.
        return Parsed(host: host, port: port, transport: "udp", requiresCredentials: false)
    }

    // MARK: - Zip

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
