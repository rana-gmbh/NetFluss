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
        lock.lock(); defer { lock.unlock() }
        let needle = host.lowercased()
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
        lock.lock(); defer { lock.unlock() }
        let needle = host.lowercased()
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
