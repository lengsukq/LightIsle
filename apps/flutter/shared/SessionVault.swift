import Foundation
import Security

enum ClientVaultSlot: String, CaseIterable {
    case session
    case davSecrets
    case loginHistory

    var legacySuffix: String {
        switch self {
        case .session: return ".login-session"
        case .davSecrets: return ".dav-local-secrets"
        case .loginHistory: return ".login-history"
        }
    }
}

struct ClientVaultPayload: Codable, Equatable {
    var version: Int = 1
    var session: String?
    var davSecrets: String?
    var loginHistory: String?

    var hasAnyValue: Bool {
        session != nil || davSecrets != nil || loginHistory != nil
    }

    func value(for slot: ClientVaultSlot) -> String? {
        switch slot {
        case .session: return session
        case .davSecrets: return davSecrets
        case .loginHistory: return loginHistory
        }
    }

    mutating func setValue(_ value: String?, for slot: ClientVaultSlot) {
        switch slot {
        case .session: session = value
        case .davSecrets: davSecrets = value
        case .loginHistory: loginHistory = value
        }
    }
}

protocol VaultItemStoring: AnyObject {
    func existsAttributesOnly() throws -> Bool
    func readData() throws -> Data?
    func upsertData(_ data: Data) throws
    func deleteItem() throws
}

/// A single device-local credential item; no account password or cloud sync.
final class KeychainSessionVault: VaultItemStoring {
    static let maxItemBytes = 8192

    private let service: String
    private let account: String

    init(service: String, account: String = "active-session") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: "LightIsleSessionVault", code: Int(status))
        }
    }

    func existsAttributesOnly() throws -> Bool {
        var request = baseQuery
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }

    func readData() throws -> Data? {
        var request = baseQuery
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = item as? Data else {
            throw NSError(domain: "LightIsleSessionVault", code: -1)
        }
        return data
    }

    func upsertData(_ data: Data) throws {
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                try check(
                    SecItemUpdate(
                        baseQuery as CFDictionary,
                        [kSecValueData as String: data] as CFDictionary
                    )
                )
            } else {
                try check(addStatus)
            }
        } else {
            try check(updateStatus)
        }
    }

    func deleteItem() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    func read() throws -> String? {
        guard let data = try readData() else { return nil }
        guard data.count <= Self.maxItemBytes,
              let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "LightIsleSessionVault", code: -1)
        }
        return value
    }

    func write(_ value: String) throws {
        let data = Data(value.utf8)
        guard data.count <= Self.maxItemBytes else {
            throw NSError(domain: "LightIsleSessionVault", code: -1)
        }
        try upsertData(data)
    }

    func clear() throws {
        try deleteItem()
    }
}

/// Consolidates `session`, `davSecrets`, and `loginHistory` into a single
/// device-local Keychain item with in-process memory caching and in-place
/// `SecItemUpdate` so macOS never destroys Keychain ACLs or prompts repeatedly.
final class ClientVaultStore {
    static let hasAnySavedKey = "lightisle.clientVault.hasAnySaved"
    static let migratedV1Key = "lightisle.clientVault.migratedV1"
    static let maxSlotBytes = 8192
    static let maxEnvelopeBytes = 32768

    private let baseService: String
    private let vaultItem: VaultItemStoring
    private let legacyItemFactory: (String, String) -> VaultItemStoring
    private let userDefaults: UserDefaults
    private var cachedPayload: ClientVaultPayload?
    private var knownPersisted = false

    init(
        baseService: String,
        userDefaults: UserDefaults = .standard,
        itemFactory: @escaping (String, String) -> VaultItemStoring = { service, account in
            KeychainSessionVault(service: service, account: account)
        }
    ) {
        self.baseService = baseService
        self.userDefaults = userDefaults
        self.legacyItemFactory = itemFactory
        self.vaultItem = itemFactory(baseService + ".vault-v1", "client-state")
    }

    func read(slot: ClientVaultSlot) throws -> String? {
        try loadIfNeeded().value(for: slot)
    }

    func write(_ value: String, to slot: ClientVaultSlot) throws {
        let slotData = Data(value.utf8)
        guard slotData.count <= Self.maxSlotBytes else {
            throw NSError(domain: "LightIsleSessionVault", code: -1)
        }
        var next = try loadIfNeeded()
        if next.value(for: slot) == value && knownPersisted {
            return
        }
        next.setValue(value, for: slot)
        try persist(next)
    }

    func clear(slot: ClientVaultSlot) throws {
        var next = try loadIfNeeded()
        if next.value(for: slot) == nil {
            return
        }
        next.setValue(nil, for: slot)
        // Update in place (writing `{ "version": 1 }` when all slots are cleared)
        // rather than calling SecItemDelete so the existing Keychain ACL stays intact.
        try persist(next)
    }

    private func persist(_ payload: ClientVaultPayload) throws {
        let encoded = try JSONEncoder().encode(payload)
        guard encoded.count <= Self.maxEnvelopeBytes else {
            throw NSError(domain: "LightIsleSessionVault", code: -1)
        }
        try vaultItem.upsertData(encoded)
        cachedPayload = payload
        knownPersisted = true
        userDefaults.set(payload.hasAnyValue, forKey: Self.hasAnySavedKey)
    }

    private func loadIfNeeded() throws -> ClientVaultPayload {
        if let cached = cachedPayload {
            return cached
        }
        let migrated = userDefaults.bool(forKey: Self.migratedV1Key)
        let hasAnySaved = userDefaults.bool(forKey: Self.hasAnySavedKey)
        if migrated && !hasAnySaved {
            let empty = ClientVaultPayload()
            cachedPayload = empty
            knownPersisted = false
            return empty
        }
        if !migrated {
            return try migrateLegacyItemsIfNeeded()
        }
        guard let data = try vaultItem.readData() else {
            let empty = ClientVaultPayload()
            cachedPayload = empty
            knownPersisted = false
            userDefaults.set(false, forKey: Self.hasAnySavedKey)
            return empty
        }
        let payload = try decodeEnvelope(data)
        cachedPayload = payload
        knownPersisted = true
        userDefaults.set(payload.hasAnyValue, forKey: Self.hasAnySavedKey)
        return payload
    }

    private func migrateLegacyItemsIfNeeded() throws -> ClientVaultPayload {
        let vaultExists = try vaultItem.existsAttributesOnly()
        var current = ClientVaultPayload()
        if vaultExists, let existingData = try vaultItem.readData() {
            current = try decodeEnvelope(existingData)
        }

        var foundLegacyStores: [(ClientVaultSlot, VaultItemStoring)] = []
        var merged = current
        for slot in ClientVaultSlot.allCases {
            let legacyStore = legacyItemFactory(baseService + slot.legacySuffix, "active-session")
            guard try legacyStore.existsAttributesOnly() else { continue }
            foundLegacyStores.append((slot, legacyStore))
            if let data = try legacyStore.readData() {
                guard data.count <= Self.maxSlotBytes,
                      let text = String(data: data, encoding: .utf8) else {
                    throw NSError(domain: "LightIsleSessionVault", code: -1)
                }
                if merged.value(for: slot) == nil {
                    merged.setValue(text, for: slot)
                }
            }
        }

        var persistedInThisCall = vaultExists
        if merged != current {
            let encoded = try JSONEncoder().encode(merged)
            guard encoded.count <= Self.maxEnvelopeBytes else {
                throw NSError(domain: "LightIsleSessionVault", code: -1)
            }
            try vaultItem.upsertData(encoded)
            persistedInThisCall = true
        }

        for (_, legacyStore) in foundLegacyStores {
            try legacyStore.deleteItem()
        }

        userDefaults.set(true, forKey: Self.migratedV1Key)
        userDefaults.set(merged.hasAnyValue, forKey: Self.hasAnySavedKey)
        cachedPayload = merged
        knownPersisted = persistedInThisCall
        return merged
    }

    private func decodeEnvelope(_ data: Data) throws -> ClientVaultPayload {
        guard data.count <= Self.maxEnvelopeBytes,
              let payload = try? JSONDecoder().decode(ClientVaultPayload.self, from: data) else {
            throw NSError(domain: "LightIsleSessionVault", code: -1)
        }
        return payload
    }
}

#if canImport(FlutterMacOS)
import FlutterMacOS
#elseif canImport(Flutter)
import Flutter
#endif

#if canImport(FlutterMacOS) || canImport(Flutter)
final class SessionVault {
    private let channel: FlutterMethodChannel
    private let store: ClientVaultStore
    private let queue = DispatchQueue(label: "lightisle.session-vault")

    init(messenger: FlutterBinaryMessenger) {
        let service = Bundle.main.bundleIdentifier ?? "top.lengsu.lightisle.client"
        store = ClientVaultStore(baseService: service)
        channel = FlutterMethodChannel(name: "lightisle/session-vault", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { return }
            guard [
                "read", "write", "clear",
                "dav.read", "dav.write", "dav.clear",
                "history.read", "history.write", "history.clear",
            ].contains(call.method) else {
                result(FlutterMethodNotImplemented)
                return
            }
            self.queue.async {
                do {
                    var value: String?
                    switch call.method {
                    case "read":
                        value = try self.store.read(slot: .session)
                    case "dav.read":
                        value = try self.store.read(slot: .davSecrets)
                    case "history.read":
                        value = try self.store.read(slot: .loginHistory)
                    case "write":
                        try self.store.write(try Self.extractValue(from: call.arguments), to: .session)
                    case "dav.write":
                        try self.store.write(try Self.extractValue(from: call.arguments), to: .davSecrets)
                    case "history.write":
                        try self.store.write(try Self.extractValue(from: call.arguments), to: .loginHistory)
                    case "dav.clear":
                        try self.store.clear(slot: .davSecrets)
                    case "history.clear":
                        try self.store.clear(slot: .loginHistory)
                    default:
                        try self.store.clear(slot: .session)
                    }
                    DispatchQueue.main.async { result(value) }
                } catch {
                    DispatchQueue.main.async {
                        result(
                            FlutterError(
                                code: "session_vault_unavailable",
                                message: "无法访问系统保存的登录状态，请解锁设备并重试。",
                                details: nil
                            )
                        )
                    }
                }
            }
        }
    }

    private static func extractValue(from arguments: Any?) throws -> String {
        guard let map = arguments as? [String: Any],
              let input = map["value"] as? String else {
            throw NSError(domain: "LightIsleSessionVault", code: -1)
        }
        return input
    }
}
#endif
