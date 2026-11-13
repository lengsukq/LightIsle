import Foundation

/// Outbound notification channels (Bark, webhook, SMTP, WeCom and DingTalk). The
/// configuration — including the Bark device key and webhook URL — lives only
/// in the consolidated login Keychain entry on this Mac and is re-sent to the
/// Core over its private stdin pipe after every restart. It is never written to
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
    static func save(_ config: NotifyChannelConfig) throws {
        try HostSecretVault.current.saveNotifyChannels(config)
    }

    static func load() -> NotifyChannelConfig? {
        HostSecretVault.current.loadNotifyChannels()
    }

    static func remove() {
        try? HostSecretVault.current.removeNotifyChannels()
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
