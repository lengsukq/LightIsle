import Foundation
import LocalAuthentication
import Security

/// Credentials are never stored in UserDefaults, SQLite, logs or the browser.
/// Access is bound to the current Touch ID enrollment on this Mac.
struct AdminCredentials: Codable, Sendable {
    let username: String
    let password: String
}

enum AdminCredentialVault {
    private static let service = "dev.lightisle.admin-credentials"
    private static let account = "local-admin"

    static func available() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            && context.biometryType == .touchID
    }

    private static func item() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func save(_ credentials: AdminCredentials) throws {
        guard available() else { throw VaultError.touchIDUnavailable }
        guard let data = try? JSONEncoder().encode(credentials) else { throw VaultError.keychainError(errSecParam) }
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet, &error
        ) else { throw VaultError.accessControl }

        // Existing credential can only be replaced after native Go verifies
        // the supplied administrator password again.
        SecItemDelete(item() as CFDictionary)
        var query = item()
        query[kSecAttrAccessControl as String] = control
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychainError(status) }
    }

    static func unlock() throws -> AdminCredentials {
        guard available() else { throw VaultError.touchIDUnavailable }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var query = item()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        context.localizedReason = "使用 Touch ID 解锁轻屿管理员凭据"
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let credentials = try? JSONDecoder().decode(AdminCredentials.self, from: data) else {
            throw VaultError.keychainError(status)
        }
        return credentials
    }

    static func remove() {
        SecItemDelete(item() as CFDictionary)
    }
}
enum VaultError: LocalizedError {
    case touchIDUnavailable
    case accessControl
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .touchIDUnavailable:
            return "此 Mac 未启用 Touch ID，请先在系统设置中录入指纹。"
        case .accessControl:
            return "无法创建 Touch ID 钥匙串保护规则。"
        case .keychainError(let code):
            if code == errSecItemNotFound { return "尚未保存凭据，请先输入正确的管理员密码并保存。" }
            if code == errSecAuthFailed || code == errSecUserCanceled { return "Touch ID 验证失败或已取消。" }
            return "钥匙串访问失败（\\(code)）。"
        }
    }
}
