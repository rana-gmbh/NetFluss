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
import Security

/// Stores per-profile VPN credentials in the login Keychain as a single generic
/// password item (username + password encoded together). Stateless and
/// `Sendable`, so it can be read from the management client's background queue.
struct VPNCredentialStore: Sendable {
    struct Credentials: Codable, Sendable {
        var username: String?
        var password: String?
    }

    private static let service = "com.local.netfluss.vpn"

    func save(account: String, username: String?, password: String?) {
        let creds = Credentials(username: username, password: password)
        guard let data = try? JSONEncoder().encode(creds) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func load(account: String) -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let creds = try? JSONDecoder().decode(Credentials.self, from: data) else {
            return nil
        }
        return creds
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - IKEv2 (NEVPNManager) password reference

    private static let ikev2Service = "com.local.netfluss.vpn.ikev2"

    /// Store the raw password as a generic-password item and return its
    /// persistent Keychain reference, which `NEVPNProtocolIKEv2.passwordReference`
    /// requires. Returns nil if the password is empty.
    @discardableResult
    func storeIKEv2Password(account: String, password: String) -> Data? {
        deleteIKEv2Password(account: account)
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return nil }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.ikev2Service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecReturnPersistentRef as String: true
        ]
        var ref: CFTypeRef?
        guard SecItemAdd(attributes as CFDictionary, &ref) == errSecSuccess else { return nil }
        return ref as? Data
    }

    /// Fetch the persistent reference for a previously stored IKEv2 password.
    func ikev2PasswordReference(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.ikev2Service,
            kSecAttrAccount as String: account,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess else { return nil }
        return ref as? Data
    }

    func deleteIKEv2Password(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.ikev2Service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
