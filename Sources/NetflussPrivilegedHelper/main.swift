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

    // Tunnels started by this helper, keyed by handle (the child pid as string).
    private let tunnelsQueue = DispatchQueue(label: "com.local.netfluss.helper.vpn")
    private var tunnels: [String: Process] = [:]

    func startVPNTunnel(
        kind: String,
        configPath: String,
        managementSocketPath: String,
        socketOwner: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Resolve the binary from the helper's own bundle — never trust a
            // client-supplied path. (TODO: also verify the binary's Team-ID code
            // signature before exec for defence in depth.)
            guard let binary = Self.bundledVPNBinaryPath(kind: kind) else {
                reply(false, "Unsupported or missing VPN binary for kind '\(kind)'.")
                return
            }
            guard FileManager.default.fileExists(atPath: configPath) else {
                reply(false, "VPN config not found.")
                return
            }

            // The helper builds the argument list itself so an imported config
            // cannot smuggle dangerous flags. For OpenVPN, scripts are disabled
            // (`--script-security 0`) so `up`/`down`/`route-up` directives can't
            // run as root; the management socket is in listen mode with a hold
            // so the app can send credentials before connecting.
            let args: [String]
            switch kind {
            case "openVPN":
                // Write a log next to the socket so the app can surface the real
                // failure reason (openvpn validates options and exits before the
                // management socket exists on many config errors).
                let logPath = (managementSocketPath as NSString).deletingPathExtension + ".log"
                args = [
                    "--config", configPath,
                    "--management", managementSocketPath, "unix",
                    "--management-client-user", socketOwner,
                    "--management-hold",
                    // Ask the management interface for auth-user-pass / private-key
                    // credentials. Without this openvpn tries the (absent) tty at
                    // startup and exits before the socket is even created.
                    "--management-query-passwords",
                    "--log", logPath,
                    "--verb", "3",
                    // Level 1 = openvpn may call its built-in helpers (ifconfig,
                    // route) to bring the tunnel up, but NOT user-defined
                    // up/down/route-up scripts from an untrusted imported config.
                    // (Level 0 also blocks ifconfig/route, so the tunnel can't
                    // be configured at all.)
                    "--script-security", "1"
                ]
            // TODO: case "wireGuard": drive wireguard-go + wg UAPI.
            default:
                reply(false, "Unsupported VPN kind '\(kind)'.")
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            // Run from the config's directory so relative ca/cert/key refs resolve.
            process.currentDirectoryURL = URL(fileURLWithPath: configPath).deletingLastPathComponent()

            do {
                try process.run()
            } catch {
                reply(false, error.localizedDescription)
                return
            }

            let handle = String(process.processIdentifier)
            self.tunnelsQueue.sync { self.tunnels[handle] = process }
            process.terminationHandler = { [weak self] _ in
                self?.tunnelsQueue.sync { self?.tunnels[handle] = nil }
            }
            reply(true, handle)
        }
    }

    func stopVPNTunnel(handle: String, withReply reply: @escaping (Bool, String?) -> Void) {
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

    /// Resolve a bundled VPN binary relative to the helper's own location
    /// (<App>/Contents/Library/HelperTools/ → <App>/Contents/Library/VPN/<bin>).
    private static func bundledVPNBinaryPath(kind: String) -> String? {
        let name: String
        switch kind {
        case "openVPN": name = "openvpn"
        case "wireGuard": name = "wireguard-go"
        default: return nil
        }
        let helperPath = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        let helperToolsDir = (helperPath as NSString).deletingLastPathComponent
        let libraryDir = (helperToolsDir as NSString).deletingLastPathComponent
        let path = (libraryDir as NSString).appendingPathComponent("VPN/\(name)")
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
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
