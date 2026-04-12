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
