import Foundation
import Security

/// The TMDB Read Access Token lives only in the login Keychain on this Mac
/// and is re-sent to the Core over its private stdin pipe after every
/// restart. It is never written to UserDefaults, SQLite, logs or screenshots,
/// and Core keeps it in memory only — the same model as the Cloudflare token.
enum TmdbSecretVault {
    private static let service = "dev.lightisle.tmdb"
    private static let account = "api-token"

    private static func item() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func save(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw VaultError.keychainError(errSecParam)
        }
        SecItemDelete(item() as CFDictionary)
        var query = item()
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychainError(status) }
    }

    static func load() -> String? {
        var query = item()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            return nil
        }
        return token
    }

    static func remove() {
        SecItemDelete(item() as CFDictionary)
    }
}

// MARK: - IPC payload models (mirroring the Go cinema package)

struct TmdbState: Decodable {
    let configured: Bool
}

/// Local (pre-IPC) validation mirroring the Core-side rules in
/// cinema.SetTMDBToken so obvious mistakes fail fast in the UI.
enum TmdbTokenValidation {
    static func isValid(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == token, !token.isEmpty else { return false }
        guard (20...2048).contains(token.count) else { return false }
        return !token.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" || $0 == " " })
    }
}

// MARK: - Trash auto-cleanup policy (mirrors the Go tasks.Retention shape)

struct TrashRetention: Codable, Equatable {
    let enabled: Bool
    let days: Int

    static let disabled = TrashRetention(enabled: false, days: 30)
}
