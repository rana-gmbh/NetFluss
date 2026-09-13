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
import CryptoKit
import Security

extension Notification.Name {
    /// Posted after a router credential/API-key is saved, so Preferences can
    /// refresh its cached "configured?" flags without polling the keychain.
    static let routerCredentialsChanged = Notification.Name("netfluss.routerCredentialsChanged")
}

/// Trust-on-first-use (TOFU) certificate store for the local router monitors
/// (UniFi / OpenWRT / OPNsense), which use self-signed certificates that the
/// system trust store can't validate.
///
/// Instead of blindly accepting *any* certificate (which lets a LAN MITM present
/// its own cert and harvest the router admin credentials/API keys we send), we
/// remember the public-key hash the router first presented and reject a silent
/// change. A genuine cert rotation surfaces as an error the user can clear by
/// re-saving the router address (which resets the pin for that host).
enum TLSPinStore {
    private static let defaultsKey = "routerTLSPins"          // [hostKey: base64 spki-sha256]
    private static let lock = NSLock()
    /// Hosts whose most recent handshake failed the pin check — read by the
    /// monitors to surface a precise "certificate changed" error.
    private static var mismatched: Set<String> = []

    static func hostKey(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

    /// The bare, lowercased host name of a router address as typed in
    /// Preferences — "https://Router.lan:8443/x", "router.lan:8443" and
    /// "router.lan" all give "router.lan" — i.e. the host part of the pin keys,
    /// which come from the TLS challenge. Without this, a URL-form address never
    /// matched its pin, so neither the reset nor the "changed" warning worked.
    static func normalizedHost(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        let host = URLComponents(string: withScheme)?.host ?? trimmed
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }

    static func pin(for hostKey: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String])?[hostKey]
    }

    static func setPin(_ hash: String, for hostKey: String) {
        lock.lock(); defer { lock.unlock() }
        var pins = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        pins[hostKey] = hash
        UserDefaults.standard.set(pins, forKey: defaultsKey)
    }

    /// Clear a host's pin so the next connection trusts-on-first-use again.
    /// Called when the user edits a router's address/credentials — an explicit
    /// action that doubles as "re-trust this router's current certificate".
    static func resetTrust(host: String) {
        let needle = normalizedHost(host)
        guard !needle.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if var pins = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] {
            pins = pins.filter { !$0.key.hasPrefix(needle + ":") && $0.key != needle }
            UserDefaults.standard.set(pins, forKey: defaultsKey)
        }
        mismatched = mismatched.filter { !$0.hasPrefix(needle + ":") && $0 != needle }
    }

    static func recordMismatch(_ hostKey: String, mismatch: Bool) {
        lock.lock(); defer { lock.unlock() }
        if mismatch { mismatched.insert(hostKey) } else { mismatched.remove(hostKey) }
    }

    /// Whether the given host (any port) recently failed the pin check.
    static func certificateChanged(host: String) -> Bool {
        let needle = normalizedHost(host)
        guard !needle.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        return mismatched.contains { $0.hasPrefix(needle + ":") || $0 == needle }
    }
}

/// URLSession delegate implementing the TOFU policy in `TLSPinStore`. Shared by
/// all router monitors; keyed per host:port so distinct routers pin separately.
final class PinningTLSDelegate: NSObject, URLSessionDelegate {
    static let shared = PinningTLSDelegate()

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        let key = TLSPinStore.hostKey(host: host, port: challenge.protectionSpace.port)

        guard let presented = Self.publicKeyHash(trust) else {
            // Can't read the key — refuse rather than trust blindly.
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        if let pinned = TLSPinStore.pin(for: key) {
            if pinned == presented {
                TLSPinStore.recordMismatch(key, mismatch: false)
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                // Pinned key changed — treat as a possible MITM. The user can
                // re-trust by re-saving the router address (resets the pin).
                TLSPinStore.recordMismatch(key, mismatch: true)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            // First contact: trust and remember this key.
            TLSPinStore.setPin(presented, for: key)
            TLSPinStore.recordMismatch(key, mismatch: false)
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    /// SHA-256 of the leaf certificate's public key. Stable across cert renewals
    /// that keep the same key; changes if the key is regenerated (which is what
    /// we want to catch). macOS 12+ APIs — fine for the macOS 13 minimum.
    private static func publicKeyHash(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }
}

/// Precise, actionable wording for router connection failures, shared by the
/// popover (NetworkMonitor) and the OPNsense credential test. Every transport
/// and TLS failure used to read as a generic "cannot reach", which hid the two
/// real 2.5 causes — HTTPS-only bare addresses and a changed pinned
/// certificate (issue #56).
enum RouterConnectionDiagnosis {
    static let preferencesRetrustHint = "To re-trust it, re-enter the router address in Preferences."

    /// Non-nil when the router's pinned certificate changed.
    static func certificateChangedMessage(router: String, host: String, retrustHint: String) -> String? {
        guard TLSPinStore.certificateChanged(host: host) else { return nil }
        return "\(router)'s TLS certificate changed since NetFluss first trusted it. "
            + "If you didn't change the router, this could be an interception attempt. "
            + retrustHint
    }

    /// - Parameter allowsHTTP: whether this router's monitor honours an
    ///   explicit `http://` address (OPNsense, OpenWRT — not UniFi).
    static func transportMessage(router: String, host: String, error: URLError?, allowsHTTP: Bool) -> String {
        if let changed = certificateChangedMessage(router: router, host: host, retrustHint: preferencesRetrustHint) {
            return changed
        }
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = address.contains("://")
        let hostName = TLSPinStore.normalizedHost(address)
        let explicitPort = URLComponents(string: hasScheme ? address : "https://\(address)")?.port
        let usesHTTPS = !hasScheme || address.lowercased().hasPrefix("https://")
        // A TLS failure means *something* answered on that port (often plain
        // HTTP), so keep the port in the suggestion; a refused connection means
        // nothing listens there, so suggest the default HTTP port instead.
        func httpHint(keepingPort: Bool) -> String {
            guard allowsHTTP, usesHTTPS else { return "" }
            let port = keepingPort ? explicitPort.map { ":\($0)" } ?? "" : ""
            return " If its web interface uses plain HTTP, enter the address as http://\(hostName)\(port)."
        }

        guard let error else { return "Cannot reach \(router) at \(address)." }
        switch error.code {
        case .cannotConnectToHost:
            guard usesHTTPS else {
                return "\(router) at \(address) refused the connection. Check the address and port."
            }
            let portHint = explicitPort == nil
                ? " If HTTPS runs on another port, enter https://\(hostName):<port>."
                : ""
            return "\(router) at \(address) refused the HTTPS connection on port \(explicitPort ?? 443).\(httpHint(keepingPort: false))\(portHint)"
        case .timedOut:
            return "\(router) at \(address) did not respond in time."
        case .cannotFindHost, .dnsLookupFailed:
            return "Cannot resolve \(hostName). Check the router address."
        case .notConnectedToInternet, .networkConnectionLost:
            return "Lost the network connection to \(router) at \(address)."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired, .cancelled:
            // .cancelled is what PinningTLSDelegate's refusal surfaces as.
            return "The HTTPS (TLS) connection to \(router) at \(address) failed.\(httpHint(keepingPort: true))"
        case .appTransportSecurityRequiresSecureConnection:
            return "macOS blocks unencrypted HTTP to \(hostName). Use the router's IP address or HTTPS."
        default:
            return "Cannot reach \(router) at \(address) (\(error.localizedDescription))."
        }
    }
}
