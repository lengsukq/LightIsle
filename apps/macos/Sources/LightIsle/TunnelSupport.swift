import Foundation
import Security

/// The Cloudflare API token lives only in the login Keychain on this Mac and
/// is re-sent to the Core over its private stdin pipe after every restart.
/// It is never written to UserDefaults, SQLite or logs. Unlike the admin
/// vault there is no biometry gate: the Core needs the token silently each
/// time it comes online.
enum TunnelSecretVault {
    private static let service = "dev.lightisle.tunnel"
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

// MARK: - IPC payload models (mirroring the Go tunnel package)

struct TunnelState: Decodable {
    let mode: String
    let status: String
    let url: String?
    let tunnelId: String?
    let tunnelName: String?
    let binary: String?
    let binaryFound: Bool
    let pid: Int?
    let error: String?
    let lastLine: String?

    var statusDescription: String {
        switch status {
        case "online": return "在线"
        case "starting": return "启动中…"
        case "error": return "异常"
        default: return "已停止"
        }
    }
}

struct TunnelEntry: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String
    let connections: Int
    let remoteConfig: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case connections = "conns_active"
        case configSource = "config_src"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(String.self, forKey: .status)
        connections = (try? container.decode(Int.self, forKey: .connections)) ?? 0
        let source = (try? container.decode(String.self, forKey: .configSource)) ?? ""
        remoteConfig = source == "cloudflare"
    }
}

struct TunnelAccount: Decodable, Identifiable {
    let id: String
    let name: String
}

struct TunnelZone: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String
}

struct TunnelIngressRule: Codable, Identifiable, Equatable {
    let hostname: String?
    let service: String

    var id: String { (hostname ?? "（全部请求）") + " → " + service }
    var isCatchAll: Bool { hostname == nil || hostname?.isEmpty == true }
}

/// One tunnel entry plus its currently applied ingress rules, as presented
/// in the management sheet.
struct TunnelDetail: Identifiable {
    let entry: TunnelEntry
    var ingress: [TunnelIngressRule]
    var id: String { entry.id }
}
