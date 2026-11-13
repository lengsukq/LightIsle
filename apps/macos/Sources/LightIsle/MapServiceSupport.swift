import Foundation

/// Only the native Mac owner may configure this shared tile-service key.
/// Kept in the consolidated Keychain entry, mirrored to the Core through
/// private stdin IPC, and never exposed in a remote HTTP response or to
/// Flutter/Web preferences.
enum MapSecretVault {
    static func valid(_ value: String) -> Bool {
        guard (8...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { value in
            (48...57).contains(value) || (65...90).contains(value) ||
            (97...122).contains(value) || value == 45 || value == 95
        }
    }

    static func save(_ value: String) throws {
        guard valid(value) else {
            throw HostSecretVaultError.invalidInput
        }
        try HostSecretVault.current.saveTiandituKey(value)
    }

    static func load() -> String? {
        guard let key = HostSecretVault.current.loadTiandituKey(), valid(key) else {
            return nil
        }
        return key
    }

    static func remove() throws {
        try HostSecretVault.current.removeTiandituKey()
    }
}

struct MapServiceState: Decodable {
    let configured: Bool
}
