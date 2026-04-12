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
import NetflussHelperShared
import ServiceManagement

enum PrivilegedCommandStatus {
    static let helperApprovalRequired: Int32 = -20_001
    static let helperRegistrationFailed: Int32 = -20_002
    static let helperConnectionFailed: Int32 = -20_003
}

actor PrivilegedHelperManager {
    static let shared = PrivilegedHelperManager()
    private static let appServiceErrorDomain = "SMAppServiceErrorDomain"

    private let service = SMAppService.daemon(plistName: NetflussHelperConstants.plistName)

    func setDNS(serviceName: String, servers: [String]) async -> CommandResult? {
        await performIfAvailable { helper, reply in
            helper.setDNS(service: serviceName, servers: servers, withReply: reply)
        }
    }

    func reconnectEthernet(interfaceName: String) async -> CommandResult? {
        await performIfAvailable { helper, reply in
            helper.reconnectEthernet(interfaceName: interfaceName, withReply: reply)
        }
    }

    private func performIfAvailable(
        _ invocation: @escaping (NetflussPrivilegedHelperProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) async -> CommandResult? {
        guard Self.hasBundledHelper else { return nil }
        if let readinessFailure = ensureServiceReady() {
            return readinessFailure
        }
        let initialResult = await performXPCInvocation(invocation)
        guard initialResult.terminationStatus == PrivilegedCommandStatus.helperConnectionFailed else {
            return initialResult
        }

        guard repairRegistration() == nil else {
            return initialResult
        }

        return await performXPCInvocation(invocation)
    }

    private func ensureServiceReady() -> CommandResult? {
        switch service.status {
        case .enabled:
            return nil
        case .requiresApproval:
            return Self.failure(
                status: PrivilegedCommandStatus.helperApprovalRequired,
                message: "Approve the Netfluss helper in System Settings, then try again."
            )
        case .notRegistered, .notFound:
            do {
                try service.register()
            } catch let error as NSError {
                if error.domain == Self.appServiceErrorDomain,
                   error.code == Int(kSMErrorAlreadyRegistered) {
                    return validateServiceStatus()
                }
                return Self.failure(
                    status: PrivilegedCommandStatus.helperRegistrationFailed,
                    message: Self.registrationErrorMessage(for: error)
                )
            }
            return validateServiceStatus()
        @unknown default:
            return Self.failure(
                status: PrivilegedCommandStatus.helperRegistrationFailed,
                message: "The privileged helper returned an unknown status."
            )
        }
    }

    private func validateServiceStatus() -> CommandResult? {
        switch service.status {
        case .enabled:
            return nil
        case .requiresApproval:
            return Self.failure(
                status: PrivilegedCommandStatus.helperApprovalRequired,
                message: "Approve the Netfluss helper in System Settings, then try again."
            )
        case .notRegistered:
            return Self.failure(
                status: PrivilegedCommandStatus.helperRegistrationFailed,
                message: "The privileged helper could not be registered."
            )
        case .notFound:
            return Self.failure(
                status: PrivilegedCommandStatus.helperRegistrationFailed,
                message: "The privileged helper bundle is incomplete."
            )
        @unknown default:
            return Self.failure(
                status: PrivilegedCommandStatus.helperRegistrationFailed,
                message: "The privileged helper returned an unknown status."
            )
        }
    }

    private func repairRegistration() -> CommandResult? {
        if service.status != .notRegistered {
            do {
                try service.unregister()
            } catch let error as NSError {
                if error.code != Int(kSMErrorJobNotFound) {
                    return Self.failure(
                        status: PrivilegedCommandStatus.helperRegistrationFailed,
                        message: Self.registrationErrorMessage(for: error)
                    )
                }
            }
        }

        do {
            try service.register()
        } catch let error as NSError {
            if error.domain == Self.appServiceErrorDomain,
               error.code == Int(kSMErrorAlreadyRegistered) {
                return validateServiceStatus()
            }
            return Self.failure(
                status: PrivilegedCommandStatus.helperRegistrationFailed,
                message: Self.registrationErrorMessage(for: error)
            )
        }

        return validateServiceStatus()
    }

    private func performXPCInvocation(
        _ invocation: @escaping (NetflussPrivilegedHelperProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(
                machServiceName: NetflussHelperConstants.machServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = Self.helperInterface

            let lock = NSLock()
            var finished = false

            func finish(_ result: CommandResult) {
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }
                finished = true
                connection.invalidationHandler = nil
                connection.interruptionHandler = nil
                lock.unlock()

                connection.invalidate()
                continuation.resume(returning: result)
            }

            connection.interruptionHandler = {
                finish(
                    Self.failure(
                        status: PrivilegedCommandStatus.helperConnectionFailed,
                        message: "The privileged helper was interrupted."
                    )
                )
            }
            connection.invalidationHandler = {
                finish(
                    Self.failure(
                        status: PrivilegedCommandStatus.helperConnectionFailed,
                        message: "The privileged helper connection was invalidated."
                    )
                )
            }

            connection.activate()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                finish(
                    Self.failure(
                        status: PrivilegedCommandStatus.helperConnectionFailed,
                        message: Self.connectionErrorMessage(for: error)
                    )
                )
            }

            guard let helper = proxy as? NetflussPrivilegedHelperProtocol else {
                finish(
                    Self.failure(
                        status: PrivilegedCommandStatus.helperConnectionFailed,
                        message: "The privileged helper connection could not be created."
                    )
                )
                return
            }

            invocation(helper) { success, message in
                finish(
                    CommandResult(
                        terminationStatus: success ? 0 : 1,
                        stdout: success ? (message ?? "") : "",
                        stderr: success ? "" : (message ?? "Operation failed.")
                    )
                )
            }
        }
    }

    private static func registrationErrorMessage(for error: NSError) -> String {
        if error.domain == appServiceErrorDomain {
            switch error.code {
            case Int(kSMErrorLaunchDeniedByUser):
                return "Approve the Netfluss helper in System Settings, then try again."
            case Int(kSMErrorInvalidSignature):
                return "The privileged helper is not signed correctly."
            case Int(kSMErrorJobPlistNotFound), Int(kSMErrorInvalidPlist), Int(kSMErrorToolNotValid):
                return "The privileged helper bundle is incomplete."
            case Int(kSMErrorAuthorizationFailure):
                return "Administrator approval was denied."
            case Int(kSMErrorServiceUnavailable):
                return "macOS could not reach Service Management."
            default:
                break
            }
        }

        if let firstLine = error.localizedDescription
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return firstLine
        }

        return "The privileged helper could not be registered."
    }

    private static func connectionErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        if let firstLine = nsError.localizedDescription
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return firstLine
        }
        return "The privileged helper could not be reached."
    }

    private static func failure(status: Int32, message: String) -> CommandResult {
        CommandResult(terminationStatus: status, stdout: "", stderr: message)
    }

    private static var helperInterface: NSXPCInterface = {
        NSXPCInterface(with: NetflussPrivilegedHelperProtocol.self)
    }()

    private static var hasBundledHelper: Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let fileManager = FileManager.default
        let helperURL = Bundle.main.bundleURL.appendingPathComponent(NetflussHelperConstants.helperBundleProgram)
        let plistURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons")
            .appendingPathComponent(NetflussHelperConstants.plistName)

        return fileManager.isExecutableFile(atPath: helperURL.path) &&
            fileManager.fileExists(atPath: plistURL.path)
    }
}
