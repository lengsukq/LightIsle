import Foundation

/// The TMDB Read Access Token lives only in the consolidated login Keychain
/// entry on this Mac and is re-sent to the Core over its private stdin pipe
/// after every restart. It is never written to UserDefaults, SQLite, logs or
/// screenshots, and Core keeps it in memory only.
enum TmdbSecretVault {
    static func save(_ token: String) throws {
        try HostSecretVault.current.saveTmdbToken(token)
    }

    static func load() -> String? {
        HostSecretVault.current.loadTmdbToken()
    }

    static func remove() {
        try? HostSecretVault.current.removeTmdbToken()
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
