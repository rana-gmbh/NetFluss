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
        DispatchQueue.global(qos: .userInitiated).async {
            let args = ["/usr/sbin/networksetup", "-setdnsservers", service] + (servers.isEmpty ? ["empty"] : servers)
            let result = Self.runCommand(arguments: args)
            reply(result.success, result.message)
        }
    }

    func reconnectEthernet(interfaceName: String, withReply reply: @escaping (Bool, String?) -> Void) {
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
    private var wgTunnels: [String: String] = [:]  // WireGuard: handle(iface) -> temp .conf path

    func startVPNTunnel(
        kind: String,
        configPath: String,
        managementSocketPath: String,
        socketOwner: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard FileManager.default.fileExists(atPath: configPath) else {
                reply(false, "VPN config not found.")
                return
            }
            switch kind {
            case "openVPN":
                self.startOpenVPN(configPath: configPath, managementSocketPath: managementSocketPath, socketOwner: socketOwner, reply: reply)
            case "wireGuard":
                self.startWireGuard(configPath: configPath, managementSocketPath: managementSocketPath, reply: reply)
            default:
                reply(false, "Unsupported VPN kind '\(kind)'.")
            }
        }
    }

    private func startOpenVPN(configPath: String, managementSocketPath: String, socketOwner: String, reply: @escaping (Bool, String?) -> Void) {
        guard let binary = Self.bundledVPNBinaryPath(kind: "openVPN") else {
            reply(false, "Missing bundled openvpn binary.")
            return
        }
        // Write a log next to the socket so the app can surface the real failure
        // reason (openvpn validates options and exits before the socket exists on
        // many config errors). script-security 1 lets openvpn call its built-in
        // ifconfig/route but not user-defined up/down scripts from the config.
        let logPath = (managementSocketPath as NSString).deletingPathExtension + ".log"
        let args = [
            "--config", configPath,
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
        process.currentDirectoryURL = URL(fileURLWithPath: configPath).deletingLastPathComponent()

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

        do {
            try process.run()
        } catch {
            reply(false, error.localizedDescription)
            return
        }
        let handle = String(process.processIdentifier)
        tunnelsQueue.sync { tunnels[handle] = process }
        process.terminationHandler = { [weak self] proc in
            let tail = outputPipe.fileHandleForReading.availableData
            if !tail.isEmpty { captured.append(tail) }
            outputPipe.fileHandleForReading.readabilityHandler = nil
            Self.appendCapturedOutput(captured.data, terminationStatus: proc.terminationStatus, to: logPath)
            self?.tunnelsQueue.sync { self?.tunnels[handle] = nil }
        }
        reply(true, handle)
    }

    private func startWireGuard(configPath: String, managementSocketPath: String, reply: @escaping (Bool, String?) -> Void) {
        // Diagnostics log the app can read back (see readVPNLog): records the tools,
        // their architecture, the exact command, and wg-quick's full output — so a
        // failed bring-up produces an actionable report instead of a bare errno.
        let logPath = (managementSocketPath as NSString).deletingPathExtension + ".log"
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
        // Remove any stale temp configs from earlier runs that aren't backing a
        // live tunnel (they'd otherwise accumulate in /tmp holding VPN secrets).
        Self.cleanupStaleWireGuardConfigs(keeping: tunnelsQueue.sync { Set(wgTunnels.values) })

        // wg-quick derives the interface name from the config filename, which
        // must be a valid (≤15 char) interface name — copy to a short temp name.
        let name = "nf" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let tmpConf = "/tmp/\(name).conf"
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            // Create with 0600 up front: the config holds the WireGuard private and
            // pre-shared keys, and /tmp is world-readable (wg-quick even warns about
            // it). Creating with restricted perms avoids a world-readable window.
            guard FileManager.default.createFile(atPath: tmpConf, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            Self.writeVPNLog("Could not stage config: \(error.localizedDescription)", to: logPath)
            reply(false, error.localizedDescription)
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
        header += "command: bash wg-quick up \(tmpConf)\n"

        let result = Self.runProcess(bashPath, [wgQuick, "up", tmpConf], env: env)
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
            tunnelsQueue.sync { wgTunnels[iface] = tmpConf }
            reply(true, iface)
        } else {
            try? FileManager.default.removeItem(atPath: tmpConf)
            reply(false, result.message ?? "wg-quick up failed.")
        }
    }

    /// Delete our leftover `/tmp/nf*.conf` staging files that aren't backing a
    /// live tunnel. Scoped to the `nf`-prefixed `.conf` names we create, so it can
    /// never touch unrelated files; `keep` holds the paths of active tunnels.
    private static func cleanupStaleWireGuardConfigs(keeping keep: Set<String>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/tmp") else { return }
        for entry in entries where entry.hasPrefix("nf") && entry.hasSuffix(".conf") {
            let path = "/tmp/\(entry)"
            if keep.contains(path) { continue }
            // Never remove a config whose tunnel is still live: the helper may have
            // restarted and lost its in-memory map. wg-quick's .name mapping file
            // only exists while the tunnel is up.
            let name = String(entry.dropLast(".conf".count))
            if let iface = wireGuardRealInterface(configName: name), interfaceExists(iface) { continue }
            try? fm.removeItem(atPath: path)
        }
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

    /// Overwrite a tunnel diagnostics log the app can read via `readVPNLog`
    /// (restricted to /tmp/netfluss-vpn-*.log there).
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
                self.tunnelsQueue.sync { self.wgTunnels[handle] = nil }
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
            reply(true, nil)
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
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.runCommand(arguments: ["/usr/sbin/scutil", "--nc", "start", serviceName])
            reply(result.success, result.message)
        }
    }

    func disconnectNativeVPN(serviceName: String, withReply reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.runCommand(arguments: ["/usr/sbin/scutil", "--nc", "stop", serviceName])
            reply(result.success, result.message)
        }
    }

    func readVPNLog(path: String, withReply reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Only ever read the tunnel log paths the helper itself creates.
            let name = (path as NSString).lastPathComponent
            guard (path as NSString).deletingLastPathComponent == "/tmp",
                  name.hasPrefix("netfluss-vpn-"),
                  name.hasSuffix(".log") else {
                reply(false, "Refused to read path.")
                return
            }
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                reply(false, "No log available.")
                return
            }
            reply(true, contents)
        }
    }

    private static let systemKeychainPath = "/Library/Keychains/System.keychain"

    func storeSystemVPNPassword(service: String, account: String, password: String, withReply reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Add to the System keychain with -A (any app may read, so the macOS
            // VPN agent can) and -U (update if present). The app can't write the
            // System keychain, but the root helper can.
            _ = Self.runCommand(arguments: ["/usr/bin/security", "delete-generic-password", "-s", service, "-a", account, Self.systemKeychainPath])
            let add = Self.runCommand(arguments: ["/usr/bin/security", "add-generic-password", "-U", "-A", "-s", service, "-a", account, "-w", password, Self.systemKeychainPath])
            guard add.success else {
                reply(false, add.message ?? "Could not store the VPN password.")
                return
            }
            // Fetch the persistent reference from the System keychain.
            var keychain: SecKeychain?
            guard SecKeychainOpen(Self.systemKeychainPath, &keychain) == errSecSuccess, let keychain else {
                reply(false, "Could not open the System keychain.")
                return
            }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecMatchSearchList as String: [keychain],
                kSecReturnPersistentRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var ref: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess, let data = ref as? Data else {
                reply(false, "Could not read back the password reference.")
                return
            }
            reply(true, data.base64EncodedString())
        }
    }

    func deleteSystemVPNPassword(service: String, account: String, withReply reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.runCommand(arguments: ["/usr/bin/security", "delete-generic-password", "-s", service, "-a", account, Self.systemKeychainPath])
            reply(true, nil)
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
        let url = URL(fileURLWithPath: logPath)
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: payload)
        } else {
            try? payload.write(to: url)
        }
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
