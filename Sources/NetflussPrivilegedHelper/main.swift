import Foundation
import NetflussHelperShared
import Security

private struct HelperCommandResult {
    let success: Bool
    let message: String?
}

/// Thread-safe accumulator for a child process's piped output. The pipe's
/// readability handler and the process's termination handler run on different
/// queues, so appends must be serialised.
private final class CapturedOutput {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ data: Data) { lock.lock(); buffer.append(data); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}

private final class NetflussPrivilegedHelper: NSObject, NetflussPrivilegedHelperProtocol {
    func setDNS(service: String, servers: [String], withReply reply: @escaping (Bool, String?) -> Void) {
        guard HelperInputPolicy.isServiceName(service), servers.allSatisfy(HelperInputPolicy.isIPAddress) else {
            reply(false, "Invalid DNS settings.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let args = ["/usr/sbin/networksetup", "-setdnsservers", service] + (servers.isEmpty ? ["empty"] : servers)
            let result = Self.runCommand(arguments: args)
            reply(result.success, result.message)
        }
    }

    func reconnectEthernet(interfaceName: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard HelperInputPolicy.isInterfaceName(interfaceName) else {
            reply(false, "Invalid interface name.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let down = Self.runCommand(arguments: ["/sbin/ifconfig", interfaceName, "down"])
            guard down.success else {
                reply(false, down.message)
                return
            }

            usleep(1_000_000)

            let up = Self.runCommand(arguments: ["/sbin/ifconfig", interfaceName, "up"])
            reply(up.success, up.message)
        }
    }

    func savePreferredWifiNetwork(
        interfaceName: String,
        ssid: String,
        networksetupSecurityType: String,
        password: String?,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        guard HelperInputPolicy.isInterfaceName(interfaceName),
              HelperInputPolicy.isSSID(ssid),
              HelperInputPolicy.isWifiSecurityType(networksetupSecurityType) else {
            reply(false, "Invalid Wi-Fi settings.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // networksetup -addpreferredwirelessnetworkatindex <iface> <ssid> <index> <security> [password]
            // — appends the SSID to the device's Known Networks list and (for
            // secured networks) stores the password as an "AirPort network
            // password" item in the system keychain, exactly like a join from
            // the system Wi-Fi menu.
            var args = [
                "/usr/sbin/networksetup",
                "-addpreferredwirelessnetworkatindex",
                interfaceName,
                ssid,
                "0",
                networksetupSecurityType
            ]
            if let password, !password.isEmpty {
                args.append(password)
            }
            let result = Self.runCommand(arguments: args)
            reply(result.success, result.message)
        }
    }

    // MARK: - VPN

    private let tunnelsQueue = DispatchQueue(label: "com.local.netfluss.helper.vpn")
    private var tunnels: [String: Process] = [:]   // OpenVPN: handle(pid) -> process
    private var ovpnStages: [String: String] = [:] // OpenVPN: handle(pid) -> staged profile dir
    private var wgTunnels: [String: String] = [:]  // WireGuard: handle(iface) -> staged .conf path
    private var tunnelOwners: [String: String] = [:] // Either: handle -> user who started it

    func startVPNTunnel(
        kind: String,
        configPath: String,
        managementSocketPath: String,
        socketOwner: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        guard configPath.hasPrefix("/"),
              HelperInputPolicy.isManagementSocketPath(managementSocketPath),
              HelperInputPolicy.isUserName(socketOwner) else {
            reply(false, "Invalid VPN settings.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard FileManager.default.fileExists(atPath: configPath) else {
                reply(false, "VPN config not found.")
                return
            }
            guard Self.bundledToolsAreIntact() else {
                reply(false, "The VPN tools inside NetFluss don't match its signature, so they will not be "
                    + "run as root. Reinstall NetFluss.")
                return
            }
            _ = try? Self.stageRoot()   // the tunnel's log lives there too
            let logPath = Self.logPath(forSocket: managementSocketPath)
            switch kind {
            case "openVPN":
                self.startOpenVPN(configPath: configPath, managementSocketPath: managementSocketPath, logPath: logPath, socketOwner: socketOwner, reply: reply)
            case "wireGuard":
                self.startWireGuard(configPath: configPath, logPath: logPath, socketOwner: socketOwner, reply: reply)
            default:
                reply(false, "Unsupported VPN kind '\(kind)'.")
            }
        }
    }

    private func startOpenVPN(configPath: String, managementSocketPath: String, logPath: String, socketOwner: String, reply: @escaping (Bool, String?) -> Void) {
        guard let binary = Self.bundledVPNBinaryPath(kind: "openVPN") else {
            reply(false, "Missing bundled openvpn binary.")
            return
        }
        // The config is user-imported and we're about to run openvpn as ROOT, so
        // it is checked and then run from a private copy: the original sits in the
        // user's Library, where anything running as the user could change it
        // after the check.
        let stage: String
        do {
            Self.cleanupStaleStages(keeping: tunnelsQueue.sync { Set(ovpnStages.values) })
            stage = try Self.stageOpenVPNProfile(from: configPath)
        } catch {
            let message = Self.refusalMessage(error, kind: "OpenVPN")
            Self.writeVPNLog("Refused config: \(message)", to: logPath)
            reply(false, message)
            return
        }
        let stagedConfig = (stage as NSString).appendingPathComponent(Self.stagedOpenVPNConfigName)
        // Write a log next to the socket so the app can surface the real failure
        // reason (openvpn validates options and exits before the socket exists on
        // many config errors). script-security 1 lets openvpn call its built-in
        // ifconfig/route but not user-defined up/down scripts from the config.
        let args = [
            "--config", stagedConfig,
            "--management", managementSocketPath, "unix",
            "--management-client-user", socketOwner,
            "--management-hold",
            "--management-query-passwords",
            "--log", logPath,
            "--verb", "3",
            "--script-security", "1"
        ]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: stage)

        // Capture openvpn's stdout/stderr. Fatal early-init and option-parse
        // errors (bad directive, unreadable cert, dyld/exec failure) are printed
        // here and openvpn exits BEFORE its `--log` file is usable, so without
        // this the app only ever sees the generic "couldn't reach the management
        // interface" error. We drain the pipe continuously (so it can't fill and
        // stall openvpn) and, on exit, append what we captured to the log file so
        // the existing `readVPNLog` path surfaces the real reason.
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let captured = CapturedOutput()
        outputPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { fh.readabilityHandler = nil } else { captured.append(data) }
        }

        // Set before launch: a config error can end openvpn before `run()` returns,
        // and that output is the whole point of the handler.
        process.terminationHandler = { [weak self] proc in
            let tail = outputPipe.fileHandleForReading.availableData
            if !tail.isEmpty { captured.append(tail) }
            outputPipe.fileHandleForReading.readabilityHandler = nil
            Self.appendCapturedOutput(captured.data, terminationStatus: proc.terminationStatus, to: logPath)
            let handle = String(proc.processIdentifier)
            self?.tunnelsQueue.sync {
                self?.tunnels[handle] = nil
                self?.ovpnStages[handle] = nil
                self?.tunnelOwners[handle] = nil
            }
            try? FileManager.default.removeItem(atPath: stage)
        }

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(atPath: stage)
            reply(false, error.localizedDescription)
            return
        }
        let handle = String(process.processIdentifier)
        tunnelsQueue.sync {
            // The process may already be gone, in which case the stage is too.
            guard process.isRunning else { return }
            tunnels[handle] = process
            ovpnStages[handle] = stage
            tunnelOwners[handle] = socketOwner
        }
        reply(true, handle)
    }

    private func startWireGuard(configPath: String, logPath: String, socketOwner: String, reply: @escaping (Bool, String?) -> Void) {
        // Diagnostics log the app can read back (see readVPNLog): records the tools,
        // their architecture, the exact command, and wg-quick's full output — so a
        // failed bring-up produces an actionable report instead of a bare errno.
        guard let toolsDir = Self.vpnToolsDir() else {
            Self.writeVPNLog("Missing bundled WireGuard tools (no VPN tools dir).", to: logPath)
            reply(false, "Missing bundled WireGuard tools.")
            return
        }
        let bashPath = toolsDir + "/bash"
        let wgQuick = toolsDir + "/wg-quick"
        guard FileManager.default.isExecutableFile(atPath: bashPath),
              FileManager.default.fileExists(atPath: wgQuick) else {
            Self.writeVPNLog("Missing bundled WireGuard tools at \(toolsDir).", to: logPath)
            reply(false, "Missing bundled WireGuard tools.")
            return
        }
        // Remove any stale staged configs from earlier runs that aren't backing a
        // live tunnel (they'd otherwise accumulate, holding VPN secrets).
        Self.cleanupStaleWireGuardConfigs(keeping: tunnelsQueue.sync { Set(wgTunnels.values) })

        // wg-quick derives the interface name from the config filename, which
        // must be a valid (≤15 char) interface name — copy to a short temp name.
        let name = "nf" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let stagedConf: String
        var routeNote: String?
        do {
            let bytes = try Self.readProfileFile(atPath: configPath)
            // wg-quick evals PostUp and friends as root; see WireGuardConfigPolicy.
            try WireGuardConfigPolicy.validate(bytes)
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                throw VPNConfigRefusal.malformed("it is not valid UTF-8")
            }
            // Strip `DNS`/`DNS =` lines so wg-quick does NOT manage DNS (issue #48),
            // and route any PRIVATE DNS server through the tunnel so the DNS we apply
            // ourselves is actually reachable (issue #50 point 2). See stageWireGuardConfig.
            // Line endings first: Swift's "\r\n" is one Character, so the line-based
            // helpers below would see a Windows-format file as a single line.
            let raw = text.replacingOccurrences(of: "\r\n", with: "\n")
            let staged: String
            (staged, routeNote) = Self.stageWireGuardConfig(from: raw)
            // Create with 0600 up front: the config holds the WireGuard private and
            // pre-shared keys. The folder is root-only too, so wg-quick's world-
            // accessible warning has nothing to warn about.
            stagedConf = try Self.stageRoot() + "/\(name).conf"
            guard FileManager.default.createFile(atPath: stagedConf, contents: Data(staged.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            let message = Self.refusalMessage(error, kind: "WireGuard")
            Self.writeVPNLog("Could not stage config: \(message)", to: logPath)
            reply(false, message)
            return
        }
        // wg-quick needs this dir for its control socket; create it up front so a
        // missing /var/run/wireguard can't be the failure. Put the tools dir first
        // on PATH so wg-quick always finds our wireguard-go/wg (not a stray copy).
        try? FileManager.default.createDirectory(atPath: "/var/run/wireguard", withIntermediateDirectories: true)
        let env = ["PATH": "\(toolsDir):/usr/bin:/bin:/usr/sbin:/sbin",
                   "WG_QUICK_USERSPACE_IMPLEMENTATION": "wireguard-go"]

        var header = "NetFluss WireGuard bring-up\n"
        header += "toolsDir: \(toolsDir)\n"
        header += "bash:         \(Self.fileArch(bashPath))\n"
        header += "wireguard-go: \(Self.fileArch(toolsDir + "/wireguard-go"))\n"
        header += "wg:           \(Self.fileArch(toolsDir + "/wg"))\n"
        if let routeNote { header += "dns-routing: \(routeNote)\n" }
        header += "command: bash wg-quick up \(stagedConf)\n"

        let result = Self.runProcess(bashPath, [wgQuick, "up", stagedConf], env: env)
        // On macOS the WireGuard device is a utunN, NOT the config name — wg-quick
        // records the mapping in /var/run/wireguard/<name>.name. Return the REAL
        // interface so the app monitors/displays the right one; monitoring the
        // config name (which never exists as an interface) made the liveness poll
        // false-detect a drop after 5s → "stopped" in the UI and piled-up utuns.
        let iface = Self.wireGuardRealInterface(configName: name) ?? name
        Self.writeVPNLog(header + "interface: \(iface)\n\n--- wg-quick output ---\n"
            + (result.message ?? "(no output)")
            + "\n\nresult: \(result.success ? "success" : "FAILED")", to: logPath)
        if result.success {
            tunnelsQueue.sync {
                wgTunnels[iface] = stagedConf
                tunnelOwners[iface] = socketOwner
            }
            reply(true, iface)
        } else {
            try? FileManager.default.removeItem(atPath: stagedConf)
            reply(false, result.message ?? "wg-quick up failed.")
        }
    }

    /// Delete our leftover `nf*.conf` staging files that aren't backing a live
    /// tunnel. Scoped to the `nf`-prefixed `.conf` names we create, so it can never
    /// touch unrelated files; `keep` holds the paths of active tunnels. `/tmp` is
    /// where helpers before version 15 staged them.
    private static func cleanupStaleWireGuardConfigs(keeping keep: Set<String>) {
        let fm = FileManager.default
        for directory in [stageRootPath, "/tmp"] {
            guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasPrefix("nf") && entry.hasSuffix(".conf") {
                let path = "\(directory)/\(entry)"
                if keep.contains(path) { continue }
                // Never remove a config whose tunnel is still live: the helper may have
                // restarted and lost its in-memory map. wg-quick's .name mapping file
                // only exists while the tunnel is up.
                let name = String(entry.dropLast(".conf".count))
                if let iface = wireGuardRealInterface(configName: name), interfaceExists(iface) { continue }
                try? fm.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Staging

    /// Root-only home for the configs root actually runs. Under /var/run, so a key
    /// that survives a crash is still gone after a reboot.
    private static let stageRootPath = "/var/run/netfluss"
    private static let ovpnStagePrefix = "ovpn-"
    private static let stagedOpenVPNConfigName = "config.ovpn"
    /// Matches the import limit in VPNConfigImporter.
    private static let maxProfileFileBytes = 5 * 1024 * 1024

    /// Creates the stage root if needed and proves it is ours: a real directory,
    /// owned by root, closed to everyone else.
    private static func stageRoot() throws -> String {
        if mkdir(stageRootPath, 0o700) != 0, errno != EEXIST {
            throw CocoaError(.fileWriteUnknown)
        }
        var info = stat()
        guard lstat(stageRootPath, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == 0,
              chmod(stageRootPath, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return stageRootPath
    }

    /// Check an OpenVPN config and copy it, with the side files it names, into a
    /// fresh private folder. Returns that folder. openvpn reads everything from
    /// there, so nothing the user can reach is looked at again after the check.
    private static func stageOpenVPNProfile(from configPath: String) throws -> String {
        let bytes = try readProfileFile(atPath: configPath)
        let sideFiles = try OpenVPNConfigPolicy.referencedFiles(in: bytes)

        let source = (configPath as NSString).deletingLastPathComponent
        let stage = try stageRoot() + "/\(ovpnStagePrefix)\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: stage, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        do {
            try writeStaged(bytes, to: (stage as NSString).appendingPathComponent(stagedOpenVPNConfigName))
            for file in sideFiles {
                guard let contents = try readSideFile(file, inProfileAt: source) else { continue }
                let destination = (stage as NSString).appendingPathComponent(file)
                try fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                try writeStaged(contents, to: destination)
            }
        } catch {
            try? fm.removeItem(atPath: stage)
            throw error
        }
        return stage
    }

    /// A side file's contents, or nil if it doesn't exist, which is left for
    /// openvpn to report in its own words. The path was already checked for `..`
    /// and absolute forms; this catches a directory link inside the profile.
    private static func readSideFile(_ file: String, inProfileAt profile: String) throws -> [UInt8]? {
        let path = (profile as NSString).appendingPathComponent(file)
        guard let root = realpath(profile, nil).map({ pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard let parent = realpath((path as NSString).deletingLastPathComponent, nil).map({ pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        }) else {
            return nil
        }
        guard parent == root || parent.hasPrefix(root + "/") else {
            throw VPNConfigRefusal.notPlainFile(file)
        }
        do {
            return try readProfileFile(atPath: path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// Read a user-owned file as root, once, refusing anything that isn't a plain
    /// file of a sensible size. O_NOFOLLOW stops a link in the profile from
    /// turning this into a read of some other file; O_NONBLOCK stops a FIFO from
    /// hanging the helper.
    private static func readProfileFile(atPath path: String) throws -> [UInt8] {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw CocoaError(.fileReadNoSuchFile) }
            throw VPNConfigRefusal.notPlainFile((path as NSString).lastPathComponent)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= maxProfileFileBytes else {
            throw VPNConfigRefusal.notPlainFile((path as NSString).lastPathComponent)
        }
        return [UInt8](try handle.readToEnd() ?? Data())
    }

    private static func writeStaged(_ bytes: [UInt8], to path: String) throws {
        guard FileManager.default.createFile(atPath: path, contents: Data(bytes),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Remove stage folders no running openvpn is using: leftovers from a helper
    /// that died before its termination handler could clean up.
    private static func cleanupStaleStages(keeping keep: Set<String>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: stageRootPath) else { return }
        for entry in entries where entry.hasPrefix(ovpnStagePrefix) {
            let path = "\(stageRootPath)/\(entry)"
            if !keep.contains(path) { try? fm.removeItem(atPath: path) }
        }
    }

    /// Where a tunnel's log lives. Root-only: openvpn opens its `--log` as root and
    /// follows links, so in world-writable /tmp a planted link would have it
    /// overwrite whatever that link pointed at.
    private static func logPath(forSocket socketPath: String) -> String {
        let name = ((socketPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return "\(stageRootPath)/\(name).log"
    }

    /// Whether the app bundle around this helper still matches its signature.
    ///
    /// `wg-quick` is a plain script inside a bundle the user owns, so nothing else
    /// checks it before root runs it. It costs about 0.2 s, once per connection.
    private static func bundledToolsAreIntact() -> Bool {
        guard let tools = vpnToolsDir() else { return false }
        let bundle = URL(fileURLWithPath: tools)   // <App>/Contents/Library/VPN
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(NetflussHelperConstants.clientCodeRequirement as CFString, [], &requirement)
                == errSecSuccess else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private static func refusalMessage(_ error: Error, kind: String) -> String {
        (error as? VPNConfigRefusal)?.message(kind: kind) ?? error.localizedDescription
    }

    /// Whether a BSD network interface with the given name currently exists.
    private static func interfaceExists(_ name: String) -> Bool {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return false }
        defer { freeifaddrs(addrs) }
        var ptr = addrs
        while let cur = ptr {
            if String(cString: cur.pointee.ifa_name) == name { return true }
            ptr = cur.pointee.ifa_next
        }
        return false
    }

    /// Drop `[Interface]` `DNS = …` lines from a WireGuard config so wg-quick
    /// doesn't set DNS or background its DNS re-applying monitor. Everything else
    /// (Address, keys, [Peer], routes) is preserved verbatim.
    private static func stripDNSDirectives(from config: String) -> String {
        config.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces).lowercased()
                return !(t.hasPrefix("dns ") || t.hasPrefix("dns=") || t == "dns")
            }
            .joined(separator: "\n")
    }

    /// Prepare a WireGuard config for `wg-quick up`:
    ///  1. Strip `DNS` directives (issue #48 — see stripDNSDirectives).
    ///  2. Route private DNS servers through the tunnel (issue #50 point 2).
    ///
    /// NetFluss applies the tunnel's DNS itself, but `wg-quick` only installs
    /// routes from `AllowedIPs`. If a PRIVATE DNS server (e.g. 192.168.15.1) isn't
    /// covered by `AllowedIPs`, no route to it goes through the tunnel — it egresses
    /// the physical default route where a VPN-internal resolver is unreachable, so
    /// DNS silently breaks. WireGuard also cryptokey-routes: a host route alone
    /// isn't enough, the address must be in the peer's `AllowedIPs`. So we add the
    /// DNS server's `/32` to the peer's `AllowedIPs`; `wg-quick` then both permits
    /// and routes it. Scoped to private (RFC1918) addresses — a public resolver is
    /// reachable off-tunnel and force-routing it would break split tunnels — and
    /// only when there's exactly one `[Peer]` (which peer owns the DNS is otherwise
    /// ambiguous, and a duplicate AllowedIP across peers is rejected by wg).
    ///
    /// Returns the staged config and an optional note for the diagnostics log.
    private static func stageWireGuardConfig(from config: String) -> (config: String, note: String?) {
        let dnsServers = wireGuardDNSServers(in: config)
        let allowed = wireGuardAllowedIPs(in: config)
        let peerCount = config.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[peer]" }.count

        let uncovered = dnsServers.filter { ip in
            isPrivateIPv4(ip) && !allowed.contains { ipv4(ip, isInside: $0) }
        }

        let staged = stripDNSDirectives(from: config)
        guard !uncovered.isEmpty else { return (staged, nil) }

        guard peerCount == 1 else {
            return (staged, "private DNS \(uncovered.joined(separator: ", ")) not in AllowedIPs; "
                + "not auto-routed (\(peerCount) peers — ambiguous). Add it to the correct peer's AllowedIPs.")
        }
        let routed = appendAllowedIPs(uncovered.map { "\($0)/32" }, to: staged)
        return (routed, "routed private DNS through tunnel (added to AllowedIPs): "
            + uncovered.joined(separator: ", "))
    }

    /// IPv4 DNS server addresses from a config's `DNS =` lines (search domains and
    /// IPv6 servers are ignored — only IPv4 auto-routing is handled).
    private static func wireGuardDNSServers(in config: String) -> [String] {
        var out: [String] = []
        for line in config.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let value = Self.value(ofKey: "dns", in: String(line)) else { continue }
            for token in value.split(separator: ",") {
                let ip = token.trimmingCharacters(in: .whitespaces)
                if ipv4ToUInt32(ip) != nil { out.append(ip) }
            }
        }
        return out
    }

    /// All `AllowedIPs =` CIDR entries across the config (all peers).
    private static func wireGuardAllowedIPs(in config: String) -> [String] {
        var out: [String] = []
        for line in config.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let value = Self.value(ofKey: "allowedips", in: String(line)) else { continue }
            for token in value.split(separator: ",") {
                let cidr = token.trimmingCharacters(in: .whitespaces)
                if !cidr.isEmpty { out.append(cidr) }
            }
        }
        return out
    }

    /// Append CIDRs to the first `AllowedIPs =` line in the config (single-peer
    /// only — callers guarantee that). Returns the config unchanged if none found.
    private static func appendAllowedIPs(_ cidrs: [String], to config: String) -> String {
        guard !cidrs.isEmpty else { return config }
        var lines = config.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for i in lines.indices where Self.value(ofKey: "allowedips", in: lines[i]) != nil {
            let trimmedRight = lines[i].replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            lines[i] = trimmedRight + ", " + cidrs.joined(separator: ", ")
            return lines.joined(separator: "\n")
        }
        return config
    }

    /// The value of a `key = value` config line (case-insensitive key match), or
    /// nil if the line isn't that key. Ignores comments and section headers.
    private static func value(ofKey key: String, in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { return nil }
        guard trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == key else { return nil }
        return String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Parse a dotted-quad IPv4 string to a UInt32, or nil if not a valid IPv4.
    private static func ipv4ToUInt32(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt16(part), octet <= 255 else { return nil }
            value = (value << 8) | UInt32(octet)
        }
        return value
    }

    /// Whether an IPv4 address is in a private (RFC1918) range.
    private static func isPrivateIPv4(_ s: String) -> Bool {
        guard let v = ipv4ToUInt32(s) else { return false }
        if (v & 0xFF00_0000) == 0x0A00_0000 { return true }  // 10.0.0.0/8
        if (v & 0xFFF0_0000) == 0xAC10_0000 { return true }  // 172.16.0.0/12
        if (v & 0xFFFF_0000) == 0xC0A8_0000 { return true }  // 192.168.0.0/16
        return false
    }

    /// Whether an IPv4 address falls inside a CIDR string (e.g. "10.0.0.0/24").
    /// Non-IPv4 CIDRs (IPv6) return false.
    private static func ipv4(_ ip: String, isInside cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard let net = ipv4ToUInt32(String(parts[0])), let addr = ipv4ToUInt32(ip) else { return false }
        let prefix = parts.count > 1 ? (UInt32(String(parts[1])) ?? 32) : 32
        guard prefix <= 32 else { return false }
        if prefix == 0 { return true }
        let mask: UInt32 = ~UInt32(0) << (32 - prefix)
        return (net & mask) == (addr & mask)
    }

    /// The real utunN device wg-quick created for a config, from the mapping file
    /// it writes at /var/run/wireguard/<configName>.name. nil if not available.
    private static func wireGuardRealInterface(configName: String) -> String? {
        let path = "/var/run/wireguard/\(configName).name"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let iface = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return iface.isEmpty ? nil : iface
    }

    /// `file -b <path>` — a concise architecture line for the diagnostics log.
    private static func fileArch(_ path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "(missing)" }
        let r = runProcess("/usr/bin/file", ["-b", path], env: nil)
        return (r.message ?? "").isEmpty ? "(unknown)" : (r.message ?? "")
    }

    /// Overwrite a tunnel diagnostics log the app can read via `readVPNLog`.
    private static func writeVPNLog(_ text: String, to path: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func stopVPNTunnel(handle: String, withReply reply: @escaping (Bool, String?) -> Void) {
        // WireGuard tunnel?
        let wgConf: String? = tunnelsQueue.sync { wgTunnels[handle] }
        if let conf = wgConf {
            DispatchQueue.global(qos: .userInitiated).async {
                var message: String? = nil
                var ok = false
                if let toolsDir = Self.vpnToolsDir() {
                    let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "WG_QUICK_USERSPACE_IMPLEMENTATION": "wireguard-go"]
                    let result = Self.runProcess(toolsDir + "/bash", [toolsDir + "/wg-quick", "down", conf], env: env)
                    ok = result.success; message = result.message
                }
                self.tunnelsQueue.sync {
                    self.wgTunnels[handle] = nil
                    self.tunnelOwners[handle] = nil
                }
                try? FileManager.default.removeItem(atPath: conf)
                reply(ok, message)
            }
            return
        }
        tunnelsQueue.async {
            guard let process = self.tunnels[handle] else {
                reply(false, "No active tunnel for handle \(handle).")
                return
            }
            if process.isRunning { process.terminate() }
            self.tunnels[handle] = nil
            self.tunnelOwners[handle] = nil
            reply(true, nil)
        }
    }

    func stopOrphanedVPNTunnels(owner: String, withReply reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let handles = self.tunnelsQueue.sync {
                self.tunnelOwners.filter { $0.value == owner }.map(\.key)
            }
            let group = DispatchGroup()
            for handle in handles {
                group.enter()
                self.stopVPNTunnel(handle: handle) { _, _ in group.leave() }
            }
            group.notify(queue: .global()) { reply(true, String(handles.count)) }
        }
    }

    func vpnTunnelStatus(handle: String, withReply reply: @escaping (Bool, String?) -> Void) {
        tunnelsQueue.async {
            // OpenVPN: a live child process. WireGuard: a tracked tunnel whose utun
            // interface still exists (the handle IS the utun name).
            let running = self.tunnels[handle]?.isRunning
                ?? (self.wgTunnels[handle] != nil && Self.interfaceExists(handle))
            reply(running, running ? "running" : "stopped")
        }
    }

    func connectNativeVPN(serviceName: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard HelperInputPolicy.isServiceName(serviceName) else {
            reply(false, "Invalid VPN service name.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.runCommand(arguments: ["/usr/sbin/scutil", "--nc", "start", serviceName])
            reply(result.success, result.message)
        }
    }

    func disconnectNativeVPN(serviceName: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard HelperInputPolicy.isServiceName(serviceName) else {
            reply(false, "Invalid VPN service name.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.runCommand(arguments: ["/usr/sbin/scutil", "--nc", "stop", serviceName])
            reply(result.success, result.message)
        }
    }

    func readVPNLog(path: String, withReply reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // `path` only names the log; it is read from the helper's own folder.
            let name = (path as NSString).lastPathComponent
            guard HelperInputPolicy.isManagementSocketPath("/tmp/\((name as NSString).deletingPathExtension).sock"),
                  name.hasSuffix(".log") else {
                reply(false, "Refused to read path.")
                return
            }
            guard let contents = try? String(contentsOfFile: "\(Self.stageRootPath)/\(name)", encoding: .utf8) else {
                reply(false, "No log available.")
                return
            }
            reply(true, contents)
        }
    }

    /// The bundled VPN tools directory, relative to the helper's own location
    /// (<App>/Contents/Library/HelperTools/ → <App>/Contents/Library/VPN).
    private static func vpnToolsDir() -> String? {
        let helperPath = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        let helperToolsDir = (helperPath as NSString).deletingLastPathComponent
        let libraryDir = (helperToolsDir as NSString).deletingLastPathComponent
        let dir = (libraryDir as NSString).appendingPathComponent("VPN")
        var isDir: ObjCBool = false
        return (FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue) ? dir : nil
    }

    /// Append openvpn's captured stdout/stderr (plus its exit status) to the
    /// tunnel log so `readVPNLog` can surface the real failure reason. openvpn
    /// exited by the time this runs, so it has released its own `--log` handle —
    /// appending is safe. A no-op when there's nothing useful to record.
    private static func appendCapturedOutput(_ data: Data, terminationStatus: Int32, to logPath: String) {
        var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A silent early exit (no output) still tells the user something via its
        // non-zero status; a clean exit (0) with no output is noise — skip it.
        if terminationStatus != 0 {
            if !text.isEmpty { text += "\n" }
            text += "openvpn exited with status \(terminationStatus)."
        }
        guard !text.isEmpty else { return }
        let payload = Data(("\n----- openvpn process output -----\n" + text + "\n").utf8)
        // O_NOFOLLOW: never follow a symlink — root must not be tricked into
        // appending to an attacker-planted link at this /tmp path. 0600 perms.
        let fd = open(logPath, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try? fh.write(contentsOf: payload)
        try? fh.close()
    }

    private static func bundledVPNBinaryPath(kind: String) -> String? {
        let name: String
        switch kind {
        case "openVPN": name = "openvpn"
        case "wireGuard": name = "wireguard-go"
        default: return nil
        }
        guard let dir = vpnToolsDir() else { return nil }
        let path = (dir as NSString).appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Run a command with an explicit executable + environment, capturing output.
    private static func runProcess(_ executable: String, _ args: [String], env: [String: String]?) -> HelperCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let env { process.environment = env }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return HelperCommandResult(success: false, message: error.localizedDescription)
        }
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = !err.isEmpty ? err : (!out.isEmpty ? out : nil)
        return HelperCommandResult(success: process.terminationStatus == 0, message: message)
    }

    private static func runCommand(arguments: [String]) -> HelperCommandResult {
        guard let executable = arguments.first else {
            return HelperCommandResult(success: false, message: "Missing command.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return HelperCommandResult(success: false, message: error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = !stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : nil)
        return HelperCommandResult(success: process.terminationStatus == 0, message: message)
    }
}

private final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let helper = NetflussPrivilegedHelper()
    private static let helperInterface = NSXPCInterface(with: NetflussPrivilegedHelperProtocol.self)

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = Self.helperInterface
        newConnection.exportedObject = helper
        newConnection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: NetflussHelperConstants.machServiceName)
listener.setConnectionCodeSigningRequirement(NetflussHelperConstants.clientCodeRequirement)
private let delegate = HelperListenerDelegate()
listener.delegate = delegate
listener.activate()
RunLoop.main.run()
