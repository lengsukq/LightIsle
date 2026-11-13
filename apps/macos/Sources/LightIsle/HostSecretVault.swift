import Foundation
import Security

/// Consolidated non-biometric host credential payload stored as a single
/// JSON object in `dev.lightisle.host-secrets`.
struct HostSecretsRecord: Codable, Equatable {
    var tmdbToken: String?
    var tiandituKey: String?
    var notifyChannels: NotifyChannelConfig?
    var tunnelAPIToken: String?
    var tunnelManualRunToken: String?

    var isEmpty: Bool {
        (tmdbToken?.isEmpty ?? true) &&
            (tiandituKey?.isEmpty ?? true) &&
            notifyChannels == nil &&
            (tunnelAPIToken?.isEmpty ?? true) &&
            (tunnelManualRunToken?.isEmpty ?? true)
    }

    func normalized() -> HostSecretsRecord {
        HostSecretsRecord(
            tmdbToken: (tmdbToken?.isEmpty == false) ? tmdbToken : nil,
            tiandituKey: (tiandituKey?.isEmpty == false) ? tiandituKey : nil,
            notifyChannels: notifyChannels,
            tunnelAPIToken: (tunnelAPIToken?.isEmpty == false) ? tunnelAPIToken : nil,
            tunnelManualRunToken: (tunnelManualRunToken?.isEmpty == false) ? tunnelManualRunToken : nil
        )
    }
}

/// Manages a single consolidated device-local Keychain item (`dev.lightisle.host-secrets`)
/// with process-lifetime in-memory caching, non-secret presence flags in `UserDefaults`,
/// ACL-preserving `SecItemUpdate` writes, and one-shot attribute-probed legacy migration.
final class HostSecretVaultStore: @unchecked Sendable {
    static let service = "dev.lightisle.host-secrets"
    static let account = "v1"
    static let itemLabel = "LightIsle Host Secrets"

    enum DefaultsKey {
        static let hasAnySaved = "lightisle.hostSecrets.hasAnySaved"
        static let migratedV1 = "lightisle.hostSecrets.migratedV1"
    }

    enum LegacySlot: CaseIterable {
        case tmdbToken
        case tiandituKey
        case notifyChannels
        case tunnelAPIToken
        case tunnelManualRunToken

        var service: String {
            switch self {
            case .tmdbToken: return "dev.lightisle.tmdb"
            case .tiandituKey: return "dev.lightisle.tianditu"
            case .notifyChannels: return "dev.lightisle.notify"
            case .tunnelAPIToken, .tunnelManualRunToken: return "dev.lightisle.tunnel"
            }
        }

        var account: String {
            switch self {
            case .tmdbToken: return "api-token"
            case .tiandituKey: return "api-key"
            case .notifyChannels: return "channels"
            case .tunnelAPIToken: return "api-token"
            case .tunnelManualRunToken: return "manual-run-token"
            }
        }
    }

    private let lock = NSLock()
    private let backend: HostKeychainBackend
    private let userDefaults: UserDefaults
    private var hasLoaded = false
    private var loadWasDeniedOrFailed = false
    private var hasPendingLegacyMigration = false
    private var cachedRecord = HostSecretsRecord()

    init(
        backend: HostKeychainBackend = SystemHostKeychainBackend(),
        userDefaults: UserDefaults = .standard
    ) {
        self.backend = backend
        self.userDefaults = userDefaults
    }

    // MARK: - Slot Accessors

    func loadTmdbToken() -> String? {
        withLock {
            ensureLoadedLocked()
            return cachedRecord.tmdbToken
        }
    }

    func saveTmdbToken(_ token: String) throws {
        guard !token.isEmpty else { throw HostSecretVaultError.invalidInput }
        try mutateRecordLocked(createIfMissing: true) { $0.tmdbToken = token }
    }

    func removeTmdbToken() throws {
        try mutateRecordLocked(createIfMissing: false) { $0.tmdbToken = nil }
    }

    func loadTiandituKey() -> String? {
        withLock {
            ensureLoadedLocked()
            return cachedRecord.tiandituKey
        }
    }

    func saveTiandituKey(_ key: String) throws {
        guard !key.isEmpty else { throw HostSecretVaultError.invalidInput }
        try mutateRecordLocked(createIfMissing: true) { $0.tiandituKey = key }
    }

    func removeTiandituKey() throws {
        try mutateRecordLocked(createIfMissing: false) { $0.tiandituKey = nil }
    }

    func loadNotifyChannels() -> NotifyChannelConfig? {
        withLock {
            ensureLoadedLocked()
            return cachedRecord.notifyChannels
        }
    }

    func saveNotifyChannels(_ config: NotifyChannelConfig) throws {
        try mutateRecordLocked(createIfMissing: true) { $0.notifyChannels = config }
    }

    func removeNotifyChannels() throws {
        try mutateRecordLocked(createIfMissing: false) { $0.notifyChannels = nil }
    }

    func loadTunnelAPIToken() -> String? {
        withLock {
            ensureLoadedLocked()
            return cachedRecord.tunnelAPIToken
        }
    }

    func saveTunnelAPIToken(_ token: String) throws {
        guard !token.isEmpty else { throw HostSecretVaultError.invalidInput }
        try mutateRecordLocked(createIfMissing: true) { $0.tunnelAPIToken = token }
    }

    func removeTunnelAPIToken() throws {
        try mutateRecordLocked(createIfMissing: false) { $0.tunnelAPIToken = nil }
    }

    func loadTunnelManualRunToken() -> String? {
        withLock {
            ensureLoadedLocked()
            return cachedRecord.tunnelManualRunToken
        }
    }

    func saveTunnelManualRunToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HostSecretVaultError.invalidInput }
        try mutateRecordLocked(createIfMissing: true) { $0.tunnelManualRunToken = trimmed }
    }

    func removeTunnelManualRunToken() throws {
        try mutateRecordLocked(createIfMissing: false) { $0.tunnelManualRunToken = nil }
    }

    // MARK: - Internal Caching & Migration

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func ensureLoadedLocked() {
        guard !hasLoaded else { return }

        let migrated = userDefaults.bool(forKey: DefaultsKey.migratedV1)
        let hasAnySaved = userDefaults.bool(forKey: DefaultsKey.hasAnySaved)

        if migrated && !hasAnySaved {
            cachedRecord = HostSecretsRecord()
            hasLoaded = true
            return
        }

        if migrated && hasAnySaved {
            switch readUnifiedRecordLocked() {
            case .found(let record):
                cachedRecord = record
                hasLoaded = true
                userDefaults.set(!record.isEmpty, forKey: DefaultsKey.hasAnySaved)
            case .notFound:
                cachedRecord = HostSecretsRecord()
                hasLoaded = true
                userDefaults.set(false, forKey: DefaultsKey.hasAnySaved)
            case .failed:
                // Keep hasAnySaved untouched so the next launch retries cleanly,
                // while caching within this process so startup doesn't re-prompt.
                cachedRecord = HostSecretsRecord()
                hasLoaded = true
                loadWasDeniedOrFailed = true
            }
            return
        }

        // One-shot migration: probe attributes first (never triggers macOS data ACL dialog).
        performFirstRunProbeAndMigrationLocked()
    }

    private func performFirstRunProbeAndMigrationLocked() {
        var unifiedExists = false
        switch probeItemExistsLocked(query: unifiedMatchQuery()) {
        case .exists:
            unifiedExists = true
        case .notFound:
            unifiedExists = false
        case .failed:
            cachedRecord = HostSecretsRecord()
            hasLoaded = true
            loadWasDeniedOrFailed = true
            hasPendingLegacyMigration = true
            return
        }

        var existingLegacy: [LegacySlot] = []
        var legacyProbeFailed = false
        for slot in LegacySlot.allCases {
            switch probeItemExistsLocked(query: legacyMatchQuery(for: slot)) {
            case .exists:
                existingLegacy.append(slot)
            case .notFound:
                break
            case .failed:
                legacyProbeFailed = true
            }
        }

        if !unifiedExists && existingLegacy.isEmpty {
            cachedRecord = HostSecretsRecord()
            hasLoaded = true
            if !legacyProbeFailed {
                userDefaults.set(false, forKey: DefaultsKey.hasAnySaved)
                userDefaults.set(true, forKey: DefaultsKey.migratedV1)
            } else {
                hasPendingLegacyMigration = true
            }
            return
        }

        var merged = HostSecretsRecord()
        if unifiedExists {
            switch readUnifiedRecordLocked() {
            case .found(let record):
                merged = record
            case .notFound:
                unifiedExists = false
            case .failed:
                cachedRecord = HostSecretsRecord()
                hasLoaded = true
                loadWasDeniedOrFailed = true
                hasPendingLegacyMigration = true
                return
            }
        }

        if existingLegacy.isEmpty {
            cachedRecord = merged
            hasLoaded = true
            userDefaults.set(!merged.isEmpty, forKey: DefaultsKey.hasAnySaved)
            if !legacyProbeFailed {
                userDefaults.set(true, forKey: DefaultsKey.migratedV1)
            } else {
                hasPendingLegacyMigration = true
            }
            return
        }

        var migratedLegacy: [LegacySlot] = []
        var anyLegacyReadFailed = legacyProbeFailed

        legacyLoop: for slot in existingLegacy {
            switch readLegacySlotLocked(slot) {
            case .found(let extracted):
                applyLegacyValueIfAbsent(extracted, into: &merged)
                migratedLegacy.append(slot)
            case .notFound:
                break
            case .failed(let status):
                anyLegacyReadFailed = true
                // Stop immediately if the user canceled so remaining items don't spam prompts.
                if status == errSecUserCanceled || status == errSecAuthFailed {
                    break legacyLoop
                }
            }
        }

        merged = merged.normalized()

        if !unifiedExists && migratedLegacy.isEmpty {
            cachedRecord = HostSecretsRecord()
            hasLoaded = true
            loadWasDeniedOrFailed = true
            hasPendingLegacyMigration = true
            return
        }

        let needsPersist = !migratedLegacy.isEmpty || unifiedExists
        if needsPersist {
            do {
                try persistRecordLocked(merged, createIfMissing: true)
            } catch {
                // Writing the consolidated entry failed; keep all legacy entries intact.
                cachedRecord = merged
                hasLoaded = true
                loadWasDeniedOrFailed = true
                hasPendingLegacyMigration = true
                return
            }
        }

        for slot in migratedLegacy {
            _ = backend.delete(legacyMatchQuery(for: slot))
        }

        cachedRecord = merged
        hasLoaded = true
        userDefaults.set(!merged.isEmpty, forKey: DefaultsKey.hasAnySaved)
        if !anyLegacyReadFailed {
            userDefaults.set(true, forKey: DefaultsKey.migratedV1)
            hasPendingLegacyMigration = false
        } else {
            hasPendingLegacyMigration = true
        }
    }

    private func mutateRecordLocked(
        createIfMissing: Bool,
        _ transform: (inout HostSecretsRecord) -> Void
    ) throws {
        try withLock {
            ensureLoadedLocked()

            if loadWasDeniedOrFailed {
                switch probeItemExistsLocked(query: unifiedMatchQuery()) {
                case .exists:
                    switch readUnifiedRecordLocked() {
                    case .found(let record):
                        cachedRecord = record
                        loadWasDeniedOrFailed = false
                    case .notFound:
                        cachedRecord = HostSecretsRecord()
                        loadWasDeniedOrFailed = false
                    case .failed(let status):
                        throw HostSecretVaultError.keychainError(status)
                    }
                case .notFound:
                    cachedRecord = HostSecretsRecord()
                    loadWasDeniedOrFailed = false
                case .failed(let status):
                    throw HostSecretVaultError.keychainError(status)
                }
            }

            var updated = cachedRecord
            transform(&updated)
            updated = updated.normalized()

            if !createIfMissing && updated == cachedRecord {
                return
            }

            try persistRecordLocked(updated, createIfMissing: createIfMissing)
            cachedRecord = updated
            hasLoaded = true
            userDefaults.set(!updated.isEmpty, forKey: DefaultsKey.hasAnySaved)
            if !hasPendingLegacyMigration {
                userDefaults.set(true, forKey: DefaultsKey.migratedV1)
            }
        }
    }

    private func persistRecordLocked(_ record: HostSecretsRecord, createIfMissing: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else {
            throw HostSecretVaultError.invalidInput
        }

        let match = unifiedMatchQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: Self.itemLabel,
        ]

        // Always update in place so the user's "Always Allow" ACL survives
        // edits as well as full clearing (writing `{}` instead of deleting).
        let updateStatus = backend.update(match, attributes: attributes)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw HostSecretVaultError.keychainError(updateStatus)
        }
        guard createIfMissing else {
            return
        }

        var addQuery = match
        addQuery.merge(attributes) { _, new in new }
        let addStatus = backend.add(addQuery)
        if addStatus == errSecDuplicateItem {
            let retryStatus = backend.update(match, attributes: attributes)
            guard retryStatus == errSecSuccess else {
                throw HostSecretVaultError.keychainError(retryStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw HostSecretVaultError.keychainError(addStatus)
        }
    }

    // MARK: - Low-Level Keychain Queries

    private enum ProbeResult {
        case exists
        case notFound
        case failed(OSStatus)
    }

    private enum UnifiedReadResult {
        case found(HostSecretsRecord)
        case notFound
        case failed(OSStatus)
    }

    private enum ExtractedLegacyValue {
        case tmdbToken(String?)
        case tiandituKey(String?)
        case notifyChannels(NotifyChannelConfig?)
        case tunnelAPIToken(String?)
        case tunnelManualRunToken(String?)
    }

    private enum LegacyReadResult {
        case found(ExtractedLegacyValue)
        case notFound
        case failed(OSStatus)
    }

    private func unifiedMatchQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func legacyMatchQuery(for slot: LegacySlot) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: slot.service,
            kSecAttrAccount as String: slot.account,
        ]
    }

    private func probeItemExistsLocked(query baseQuery: [String: Any]) -> ProbeResult {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = backend.copyMatching(query, result: &result)
        switch status {
        case errSecSuccess:
            return .exists
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status)
        }
    }

    private func readUnifiedRecordLocked() -> UnifiedReadResult {
        var query = unifiedMatchQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = backend.copyMatching(query, result: &result)
        if status == errSecItemNotFound {
            return .notFound
        }
        guard status == errSecSuccess else {
            return .failed(status)
        }
        guard let data = result as? Data, !data.isEmpty else {
            return .found(HostSecretsRecord())
        }
        guard let decoded = try? JSONDecoder().decode(HostSecretsRecord.self, from: data) else {
            return .found(HostSecretsRecord())
        }
        return .found(decoded.normalized())
    }

    private func readLegacySlotLocked(_ slot: LegacySlot) -> LegacyReadResult {
        var query = legacyMatchQuery(for: slot)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = backend.copyMatching(query, result: &result)
        if status == errSecItemNotFound {
            return .notFound
        }
        guard status == errSecSuccess else {
            return .failed(status)
        }
        guard let data = result as? Data else {
            return .failed(errSecDecode)
        }
        let extracted: ExtractedLegacyValue
        switch slot {
        case .tmdbToken:
            let token = String(data: data, encoding: .utf8)
            extracted = .tmdbToken(token?.isEmpty == false ? token : nil)
        case .tiandituKey:
            let key = String(data: data, encoding: .utf8)
            extracted = .tiandituKey(key?.isEmpty == false ? key : nil)
        case .notifyChannels:
            if data.isEmpty {
                extracted = .notifyChannels(nil)
            } else if let decoded = try? JSONDecoder().decode(NotifyChannelConfig.self, from: data) {
                extracted = .notifyChannels(decoded)
            } else {
                return .failed(errSecDecode)
            }
        case .tunnelAPIToken:
            let token = String(data: data, encoding: .utf8)
            extracted = .tunnelAPIToken(token?.isEmpty == false ? token : nil)
        case .tunnelManualRunToken:
            let token = String(data: data, encoding: .utf8)
            extracted = .tunnelManualRunToken(token?.isEmpty == false ? token : nil)
        }
        return .found(extracted)
    }

    private func applyLegacyValueIfAbsent(_ extracted: ExtractedLegacyValue, into record: inout HostSecretsRecord) {
        switch extracted {
        case .tmdbToken(let token):
            if record.tmdbToken == nil { record.tmdbToken = token }
        case .tiandituKey(let key):
            if record.tiandituKey == nil { record.tiandituKey = key }
        case .notifyChannels(let channels):
            if record.notifyChannels == nil { record.notifyChannels = channels }
        case .tunnelAPIToken(let token):
            if record.tunnelAPIToken == nil { record.tunnelAPIToken = token }
        case .tunnelManualRunToken(let token):
            if record.tunnelManualRunToken == nil { record.tunnelManualRunToken = token }
        }
    }
}

/// Process-wide access point for consolidated host secrets, plus a scoped test
/// override so standalone Swift checks never touch the user's real Keychain.
enum HostSecretVault {
    private static let lock = NSLock()
    private static var overrideStore: HostSecretVaultStore?
    private static let sharedStore = HostSecretVaultStore()

    static var current: HostSecretVaultStore {
        lock.lock()
        defer { lock.unlock() }
        return overrideStore ?? sharedStore
    }

    static func withTestingStore<T>(_ store: HostSecretVaultStore, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        let previous = overrideStore
        overrideStore = store
        lock.unlock()
        defer {
            lock.lock()
            overrideStore = previous
            lock.unlock()
        }
        return try body()
    }
}

/// Compatibility facade for Cloudflare Tunnel API and manual run tokens,
/// backed by the single `dev.lightisle.host-secrets` Keychain item.
enum TunnelSecretVault {
    static func save(_ token: String) throws {
        try HostSecretVault.current.saveTunnelAPIToken(token)
    }

    static func load() -> String? {
        HostSecretVault.current.loadTunnelAPIToken()
    }

    static func remove() throws {
        try HostSecretVault.current.removeTunnelAPIToken()
    }

    static func saveManualRunToken(_ token: String) throws {
        try HostSecretVault.current.saveTunnelManualRunToken(token)
    }

    static func loadManualRunToken() -> String? {
        HostSecretVault.current.loadTunnelManualRunToken()
    }

    static func removeManualRunToken() throws {
        try HostSecretVault.current.removeTunnelManualRunToken()
    }
}
