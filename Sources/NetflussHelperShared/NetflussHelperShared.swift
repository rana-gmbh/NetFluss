import Foundation

public enum NetflussHelperConstants {
    public static let appBundleIdentifier = "com.local.netfluss"
    public static let teamIdentifier = "D6P24X5377"
    public static let machServiceName = "com.local.netfluss.privilegedhelper"
    public static let plistName = "com.local.netfluss.privilegedhelper.plist"
    public static let helperExecutableName = "NetflussPrivilegedHelper"
    public static let helperBundleProgram = "Contents/Library/HelperTools/\(helperExecutableName)"
    public static let clientCodeRequirement = "anchor apple generic and identifier \"\(appBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
}

@objc public protocol NetflussPrivilegedHelperProtocol {
    func setDNS(service: String, servers: [String], withReply reply: @escaping (Bool, String?) -> Void)
    func reconnectEthernet(interfaceName: String, withReply reply: @escaping (Bool, String?) -> Void)
    func savePreferredWifiNetwork(
        interfaceName: String,
        ssid: String,
        networksetupSecurityType: String,
        password: String?,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    // MARK: VPN

    /// Launch a bundled VPN binary (OpenVPN/WireGuard) as root. `kind` selects
    /// the binary (resolved by the helper from its own bundle — the client never
    /// supplies the binary path). The helper builds a safe argument list itself
    /// (e.g. forcing `--script-security 0` for OpenVPN). On success the reply
    /// message carries an opaque tunnel handle used to stop / query it.
    func startVPNTunnel(
        kind: String,
        configPath: String,
        managementSocketPath: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// Terminate a tunnel previously started via `startVPNTunnel`.
    func stopVPNTunnel(handle: String, withReply reply: @escaping (Bool, String?) -> Void)

    /// Report whether the tunnel with the given handle is still running
    /// (success == running).
    func vpnTunnelStatus(handle: String, withReply reply: @escaping (Bool, String?) -> Void)

    /// Start a macOS-native (IKEv2/IPsec/L2TP) VPN service by name via `scutil`.
    func connectNativeVPN(serviceName: String, withReply reply: @escaping (Bool, String?) -> Void)

    /// Stop a macOS-native VPN service by name via `scutil`.
    func disconnectNativeVPN(serviceName: String, withReply reply: @escaping (Bool, String?) -> Void)
}
