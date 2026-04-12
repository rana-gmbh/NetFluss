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
}
