import Foundation
import NetflussHelperShared

private struct HelperCommandResult {
    let success: Bool
    let message: String?
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
                self.startWireGuard(configPath: configPath, reply: reply)
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
        do {
            try process.run()
        } catch {
            reply(false, error.localizedDescription)
            return
        }
        let handle = String(process.processIdentifier)
        tunnelsQueue.sync { tunnels[handle] = process }
        process.terminationHandler = { [weak self] _ in
            self?.tunnelsQueue.sync { self?.tunnels[handle] = nil }
        }
        reply(true, handle)
    }

    private func startWireGuard(configPath: String, reply: @escaping (Bool, String?) -> Void) {
        guard let toolsDir = Self.vpnToolsDir() else {
            reply(false, "Missing bundled WireGuard tools.")
            return
        }
        let bashPath = toolsDir + "/bash"
        let wgQuick = toolsDir + "/wg-quick"
        guard FileManager.default.isExecutableFile(atPath: bashPath),
              FileManager.default.fileExists(atPath: wgQuick) else {
            reply(false, "Missing bundled WireGuard tools.")
            return
        }
        // wg-quick derives the interface name from the config filename, which
        // must be a valid (≤15 char) interface name — copy to a short temp name.
        let name = "nf" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let tmpConf = "/tmp/\(name).conf"
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            try data.write(to: URL(fileURLWithPath: tmpConf), options: .atomic)
        } catch {
            reply(false, error.localizedDescription)
            return
        }
        let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "WG_QUICK_USERSPACE_IMPLEMENTATION": "wireguard-go"]
        let result = Self.runProcess(bashPath, [wgQuick, "up", tmpConf], env: env)
        if result.success {
            tunnelsQueue.sync { wgTunnels[name] = tmpConf }
            reply(true, name)
        } else {
            try? FileManager.default.removeItem(atPath: tmpConf)
            reply(false, result.message ?? "wg-quick up failed.")
        }
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
            let running = self.tunnels[handle]?.isRunning ?? false
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
