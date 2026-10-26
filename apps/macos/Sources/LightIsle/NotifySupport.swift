import Foundation
import Security

/// Outbound notification channels (Bark, webhook, SMTP, WeCom and DingTalk). The
/// configuration — including the Bark device key and webhook URL — lives only
/// in the login Keychain on this Mac and is re-sent to the Core over its
/// private stdin pipe after every restart. It is never written to
/// UserDefaults, SQLite, logs, or remote clients; the Core keeps it in memory
/// only, the same model as the TMDB and Cloudflare tokens.
struct NotifyChannelConfig: Codable, Equatable {
    var barkServer: String = ""
    var barkKey: String = ""
    var webhookURL: String = ""
    var allowPrivateTargets: Bool = false
    // Optional fields decode older Keychain records without a migration step.
    var smtpHost: String? = nil
    var smtpPort: Int? = nil
    var smtpUsername: String? = nil
    var smtpPassword: String? = nil
    var smtpFrom: String? = nil
    var smtpTo: String? = nil
    var wecomWebhook: String? = nil
    var dingtalkWebhook: String? = nil
    var dingtalkSecret: String? = nil

    var isEmpty: Bool {
        barkKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (smtpHost ?? "").isEmpty && (wecomWebhook ?? "").isEmpty && (dingtalkWebhook ?? "").isEmpty
    }
}

enum NotifySecretVault {
    private static let service = "dev.lightisle.notify"
    private static let account = "channels"

    private static func item() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func save(_ config: NotifyChannelConfig) throws {
        guard let data = try? JSONEncoder().encode(config) else {
            throw VaultError.keychainError(errSecParam)
        }
        SecItemDelete(item() as CFDictionary)
        var query = item()
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychainError(status) }
    }

    static func load() -> NotifyChannelConfig? {
        var query = item()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let config = try? JSONDecoder().decode(NotifyChannelConfig.self, from: data) else {
            return nil
        }
        return config
    }

    static func remove() {
        SecItemDelete(item() as CFDictionary)
    }
}

// MARK: - IPC payload models (mirroring the Go notify package)

struct NotifyStats: Decodable, Equatable {
    let configured: Bool
    let queued: Int
    let dropped: UInt64
    let failures: Int
    let backingOff: Bool
}
