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
///
/// Configs that inline their certs (`<ca>…</ca>`) need nothing extra; configs
/// that reference external files (`ca ca.crt`, `tls-auth ta.key 1`, …) need
/// those files imported too — handled by copying the referenced sidecar files
/// (single `.ovpn`) or the whole directory tree (folder / zip).
enum VPNConfigImporter {
    struct ConfigFile {
        /// Path relative to the profile directory (may contain subdirectories).
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

    /// Directives whose argument is an external file the tunnel needs.
    private static let fileDirectives: Set<String> = [
        "ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2",
        "pkcs12", "crl-verify", "extra-certs", "dh"
    ]
    private static let maxFileBytes = 5 * 1024 * 1024

    static func importOpenVPN(from url: URL) throws -> OpenVPNImport {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }

        if url.pathExtension.lowercased() == "zip" {
            return try importTree(root: try extractZip(url), suggestedName: url.deletingPathExtension().lastPathComponent)
        }
        if isDir.boolValue {
            return try importTree(root: url, suggestedName: url.lastPathComponent)
        }
        return try importSingle(url)
    }

    // MARK: - Single .ovpn (+ referenced sidecar files)

    private static func importSingle(_ url: URL) throws -> OpenVPNImport {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }
        let name = url.lastPathComponent
        var files = [ConfigFile(name: name, data: data)]

        let dir = url.deletingLastPathComponent()
        for ref in referencedFiles(in: text) where !ref.contains("..") {
            let refURL = dir.appendingPathComponent(ref)
            if let d = try? Data(contentsOf: refURL), d.count <= maxFileBytes {
                files.append(ConfigFile(name: ref, data: d))
            }
        }

        let parsed = parse(text)
        let baseName = url.deletingPathExtension().lastPathComponent
        let endpoint = VPNServerEndpoint(
            label: baseName,
            host: parsed.host ?? baseName,
            port: parsed.port,
            transport: parsed.transport,
            configFileName: name
        )
        return OpenVPNImport(
            suggestedName: baseName,
            files: files,
            endpoints: [endpoint],
            primaryFileName: name,
            requiresCredentials: parsed.requiresCredentials
        )
    }

    // MARK: - Folder / zip (copy the whole tree, one endpoint per .ovpn)

    private static func importTree(root: URL, suggestedName: String) throws -> OpenVPNImport {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw ImportError.noConfigsFound
        }

        var files: [ConfigFile] = []
        var ovpnRelPaths: [String] = []
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let rel = relativePath(of: fileURL, under: root)
            guard !rel.isEmpty, !rel.hasPrefix("__MACOSX/"), !(fileURL.lastPathComponent.hasPrefix("._")) else { continue }
            guard let data = try? Data(contentsOf: fileURL), data.count <= maxFileBytes else { continue }
            files.append(ConfigFile(name: rel, data: data))
            if fileURL.pathExtension.lowercased() == "ovpn" { ovpnRelPaths.append(rel) }
        }
        guard !ovpnRelPaths.isEmpty else { throw ImportError.noConfigsFound }

        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.data) })
        var endpoints: [VPNServerEndpoint] = []
        var requiresCredentials = false
        for rel in ovpnRelPaths.sorted() {
            let text = byName[rel].flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let parsed = parse(text)
            requiresCredentials = requiresCredentials || parsed.requiresCredentials
            let label = (rel as NSString).lastPathComponent.replacingOccurrences(of: ".ovpn", with: "")
            endpoints.append(
                VPNServerEndpoint(
                    label: label,
                    host: parsed.host ?? label,
                    port: parsed.port,
                    transport: parsed.transport,
                    configFileName: rel
                )
            )
        }

        return OpenVPNImport(
            suggestedName: suggestedName,
            files: files,
            endpoints: endpoints,
            primaryFileName: ovpnRelPaths.sorted().first!,
            requiresCredentials: requiresCredentials
        )
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") { return String(path.dropFirst(rootPath.count + 1)) }
        return url.lastPathComponent
    }

    // MARK: - Parsing

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
