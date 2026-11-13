import Foundation
import Security

/// Typed errors raised when validating or persisting non-biometric host
/// secrets in the consolidated login Keychain entry (`dev.lightisle.host-secrets`).
enum HostSecretVaultError: LocalizedError, Equatable {
    case invalidInput
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "凭据内容无效或编码失败，未写入钥匙串。"
        case .keychainError(let code):
            if code == errSecAuthFailed || code == errSecUserCanceled {
                return "钥匙串访问被拒绝或已取消。"
            }
            return "钥匙串访问失败（状态码 \(code)）。"
        }
    }
}

/// Abstract Keychain CRUD operations so tests can inspect query attributes,
/// verify read/update/delete counts, and simulate `errSecUserCanceled` without
/// touching the macOS login Keychain.
protocol HostKeychainBackend: AnyObject {
    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/// Production backend backed by the standard macOS login Keychain.
/// Deliberately omits `kSecUseDataProtectionKeychain` so locally-signed /
/// unsigned builds never trigger `-34018` (`errSecMissingEntitlement`).
final class SystemHostKeychainBackend: HostKeychainBackend {
    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, &result)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Thread-unsafe (locked by caller) in-memory Keychain test double that records
/// every query, tracks per-item identity (verifying ACL preservation when no
/// delete happens), and allows fault injection during migration or reads.
final class InMemoryHostKeychainBackend: HostKeychainBackend {
    struct StoredItem: Equatable {
        let itemID: UUID
        var service: String
        var account: String
        var synchronizable: Bool?
        var accessible: String?
        var label: String?
        var data: Data
    }

    private(set) var items: [StoredItem] = []
    private(set) var copyMatchingAttributeCalls = 0
    private(set) var copyMatchingDataCalls = 0
    private(set) var addCalls = 0
    private(set) var updateCalls = 0
    private(set) var deleteCalls = 0
    private(set) var recordedAddQueries: [[String: Any]] = []

    /// Optional fault injector receiving `(service, account, returnsData)`.
    var forcedCopyMatchingStatus: ((String, String, Bool) -> OSStatus?)?

    var itemCount: Int { items.count }

    func storedItem(service: String, account: String) -> StoredItem? {
        items.first { $0.service == service && $0.account == account }
    }

    func seedItem(service: String, account: String, data: Data, synchronizable: Bool? = nil) {
        if let index = items.firstIndex(where: { $0.service == service && $0.account == account }) {
            items[index].data = data
            items[index].synchronizable = synchronizable
        } else {
            items.append(StoredItem(
                itemID: UUID(),
                service: service,
                account: account,
                synchronizable: synchronizable,
                accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                label: nil,
                data: data
            ))
        }
    }

    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus {
        let returnsData = (query[kSecReturnData as String] as? Bool) == true
        let returnsAttributes = (query[kSecReturnAttributes as String] as? Bool) == true
        if returnsData {
            copyMatchingDataCalls += 1
        } else if returnsAttributes {
            copyMatchingAttributeCalls += 1
        }

        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        if let forced = forcedCopyMatchingStatus?(service, account, returnsData) {
            return forced
        }

        guard let match = findIndex(matching: query).map({ items[$0] }) else {
            return errSecItemNotFound
        }
        if returnsData && !returnsAttributes {
            result = match.data as CFData
            return errSecSuccess
        }
        var dict: [String: Any] = [
            kSecAttrService as String: match.service,
            kSecAttrAccount as String: match.account,
        ]
        if let sync = match.synchronizable {
            dict[kSecAttrSynchronizable as String] = sync
        }
        if let accessible = match.accessible {
            dict[kSecAttrAccessible as String] = accessible
        }
        if let label = match.label {
            dict[kSecAttrLabel as String] = label
        }
        if returnsData {
            dict[kSecValueData as String] = match.data
        }
        result = dict as CFDictionary
        return errSecSuccess
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        addCalls += 1
        recordedAddQueries.append(attributes)
        let service = attributes[kSecAttrService as String] as? String ?? ""
        let account = attributes[kSecAttrAccount as String] as? String ?? ""
        if items.contains(where: { $0.service == service && $0.account == account }) {
            return errSecDuplicateItem
        }
        let data = attributes[kSecValueData as String] as? Data ?? Data()
        items.append(StoredItem(
            itemID: UUID(),
            service: service,
            account: account,
            synchronizable: attributes[kSecAttrSynchronizable as String] as? Bool,
            accessible: attributes[kSecAttrAccessible as String] as? String,
            label: attributes[kSecAttrLabel as String] as? String,
            data: data
        ))
        return errSecSuccess
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updateCalls += 1
        guard let idx = findIndex(matching: query) else {
            return errSecItemNotFound
        }
        if let data = attributes[kSecValueData as String] as? Data {
            items[idx].data = data
        }
        if let accessible = attributes[kSecAttrAccessible as String] as? String {
            items[idx].accessible = accessible
        }
        if let label = attributes[kSecAttrLabel as String] as? String {
            items[idx].label = label
        }
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        deleteCalls += 1
        guard let idx = findIndex(matching: query) else {
            return errSecItemNotFound
        }
        items.remove(at: idx)
        return errSecSuccess
    }

    private func findIndex(matching query: [String: Any]) -> Int? {
        let service = query[kSecAttrService as String] as? String
        let account = query[kSecAttrAccount as String] as? String
        let syncFilter = query[kSecAttrSynchronizable as String] as? Bool
        return items.firstIndex { item in
            (service == nil || item.service == service) &&
                (account == nil || item.account == account) &&
                (syncFilter == nil || item.synchronizable == nil || item.synchronizable == syncFilter)
        }
    }
}
