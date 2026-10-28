import Foundation
import Security

/// Only the native Mac owner may configure this shared tile-service key.
/// Kept in Keychain, mirrored to the Core through private stdin IPC, and
/// never exposed in a remote HTTP response or to Flutter/Web preferences.
enum MapSecretVault {
    private static let service = "dev.lightisle.tianditu"
    private static let account = "api-key"

    private static func item() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func valid(_ value: String) -> Bool {
        guard (8...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { value in
            (48...57).contains(value) || (65...90).contains(value) ||
            (97...122).contains(value) || value == 45 || value == 95
        }
    }

    static func save(_ value: String) throws {
        guard valid(value), let data = value.data(using: .utf8) else {
            throw VaultError.keychainError(errSecParam)
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updated = SecItemUpdate(item() as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw VaultError.keychainError(updated) }
        var query = item()
        query.merge(attributes) { _, new in new }
        let added = SecItemAdd(query as CFDictionary, nil)
        if added == errSecDuplicateItem {
            let retried = SecItemUpdate(item() as CFDictionary, attributes as CFDictionary)
            guard retried == errSecSuccess else { throw VaultError.keychainError(retried) }
            return
        }
        guard added == errSecSuccess else { throw VaultError.keychainError(added) }
    }

    static func load() -> String? {
        var query = item()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), valid(key) else { return nil }
        return key
    }

    static func remove() throws {
        let status = SecItemDelete(item() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.keychainError(status)
        }
    }
}

struct MapServiceState: Decodable {
    let configured: Bool
}
