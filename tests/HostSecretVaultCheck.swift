import Foundation
import Security

/// Standalone regression check for `HostSecretVault` / `HostSecretVaultStore`.
/// Uses only `InMemoryHostKeychainBackend` + ephemeral `UserDefaults` suites so
/// it never touches or prompts the developer's real macOS login Keychain.
@main
struct HostSecretVaultCheck {
    private static func makeDefaults() -> (UserDefaults, String) {
        let suite = "dev.lightisle.tests.host-secrets.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    static func main() throws {
        try testEmptyStateMakesZeroKeychainCalls()
        try testFirstCleanStartupProbesAttributesOnlyOnce()
        try testSingleConsolidatedEntryInProcessCacheAndInPlaceUpdate()
        try testLegacyMigrationConsolidatesAndDeletesLegacyEntries()
        try testLegacyMigrationUserCancelPreservesUnmigratedItems()
        try testFacadeCompatibilityWrappers()
        print("HostSecretVaultCheck passed (0 real Keychain calls, single-entry, cached, in-place update, safe migration).")
    }

    private static func testEmptyStateMakesZeroKeychainCalls() throws {
        let backend = InMemoryHostKeychainBackend()
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: HostSecretVaultStore.DefaultsKey.migratedV1)
        defaults.set(false, forKey: HostSecretVaultStore.DefaultsKey.hasAnySaved)

        let store = HostSecretVaultStore(backend: backend, userDefaults: defaults)
        precondition(store.loadTmdbToken() == nil)
        precondition(store.loadTiandituKey() == nil)
        precondition(store.loadNotifyChannels() == nil)
        precondition(store.loadTunnelAPIToken() == nil)
        precondition(store.loadTunnelManualRunToken() == nil)

        precondition(backend.copyMatchingAttributeCalls == 0, "Expected 0 attribute queries in empty migrated state")
        precondition(backend.copyMatchingDataCalls == 0, "Expected 0 data reads in empty migrated state")
        precondition(backend.addCalls == 0 && backend.updateCalls == 0 && backend.deleteCalls == 0)

        // Removing from an empty store must also be a pure no-op without touching Keychain.
        try store.removeTmdbToken()
        precondition(backend.updateCalls == 0 && backend.addCalls == 0 && backend.deleteCalls == 0)
    }

    private static func testFirstCleanStartupProbesAttributesOnlyOnce() throws {
        let backend = InMemoryHostKeychainBackend()
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = HostSecretVaultStore(backend: backend, userDefaults: defaults)
        precondition(store.loadTmdbToken() == nil)
        // Probes unified + 5 legacy slots via attributes-only (never kSecReturnData!).
        precondition(backend.copyMatchingDataCalls == 0, "Attribute probe must never request secret data")
        precondition(backend.copyMatchingAttributeCalls == 6, "Expected 1 unified + 5 legacy attribute probes")
        precondition(defaults.bool(forKey: HostSecretVaultStore.DefaultsKey.migratedV1) == true)
        precondition(defaults.bool(forKey: HostSecretVaultStore.DefaultsKey.hasAnySaved) == false)

        // A second process launch with the same UserDefaults must now perform 0 Keychain queries!
        let secondLaunch = HostSecretVaultStore(backend: backend, userDefaults: defaults)
        precondition(secondLaunch.loadTunnelAPIToken() == nil)
        precondition(backend.copyMatchingAttributeCalls == 6, "Second launch must make 0 additional queries")
        precondition(backend.copyMatchingDataCalls == 0)
    }

    private static func testSingleConsolidatedEntryInProcessCacheAndInPlaceUpdate() throws {
        let backend = InMemoryHostKeychainBackend()
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: HostSecretVaultStore.DefaultsKey.migratedV1)
        defaults.set(false, forKey: HostSecretVaultStore.DefaultsKey.hasAnySaved)

        let store = HostSecretVaultStore(backend: backend, userDefaults: defaults)
        var notify = NotifyChannelConfig()
        notify.barkServer = "https://api.day.app"
        notify.barkKey = "bark-secret-key"

        try store.saveTmdbToken("tmdb-v1")
        try store.saveTiandituKey("tianditu-v1")
        try store.saveNotifyChannels(notify)
        try store.saveTunnelAPIToken("cf-api-v1")
        try store.saveTunnelManualRunToken("  cf-run-v1 \n")

        // All 5 credentials must live inside exactly 1 Keychain item (`dev.lightisle.host-secrets` / `v1`).
        precondition(backend.itemCount == 1, "Expected exactly 1 consolidated Keychain item, got \(backend.itemCount)")
        guard let initialItem = backend.storedItem(
            service: HostSecretVaultStore.service,
            account: HostSecretVaultStore.account
        ) else {
            fatalError("Consolidated Keychain entry missing")
        }
        precondition(initialItem.synchronizable == false, "Consolidated item must disable iCloud Keychain sync")
        precondition(
            initialItem.accessible == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String),
            "Unexpected kSecAttrAccessible value"
        )
        // Guard against `-34018` (`errSecMissingEntitlement`) in unsigned/locally signed builds.
        for addQuery in backend.recordedAddQueries {
            precondition(
                addQuery[kSecUseDataProtectionKeychain as String] == nil,
                "kSecUseDataProtectionKeychain must never be set on macOS host secrets"
            )
        }
        let originalItemID = initialItem.itemID
        precondition(defaults.bool(forKey: HostSecretVaultStore.DefaultsKey.hasAnySaved) == true)

        // Simulate a brand-new app process reading all 5 secrets multiple times:
        // must execute `SecItemCopyMatching(kSecReturnData)` at most ONCE!
        let relaunched = HostSecretVaultStore(backend: backend, userDefaults: defaults)
        let dataReadsBefore = backend.copyMatchingDataCalls
        for _ in 0..<5 {
            precondition(relaunched.loadTmdbToken() == "tmdb-v1")
            precondition(relaunched.loadTiandituKey() == "tianditu-v1")
            precondition(relaunched.loadNotifyChannels()?.barkKey == "bark-secret-key")
            precondition(relaunched.loadTunnelAPIToken() == "cf-api-v1")
            precondition(relaunched.loadTunnelManualRunToken() == "cf-run-v1")
        }
        precondition(
            backend.copyMatchingDataCalls - dataReadsBefore == 1,
            "Process lifetime cache must read Keychain data at most 1 time"
        )

        // Updating and clearing all slots must use in-place `SecItemUpdate` (0 `SecItemDelete`)
        // so the item's `itemID` (representing its macOS "Always Allow" ACL) never changes!
        try relaunched.saveTmdbToken("tmdb-v2")
        try relaunched.removeTmdbToken()
        try relaunched.removeTiandituKey()
        try relaunched.removeNotifyChannels()
        try relaunched.removeTunnelAPIToken()
        try relaunched.removeTunnelManualRunToken()

        precondition(backend.deleteCalls == 0, "Updating or clearing slots must never call SecItemDelete")
        precondition(backend.itemCount == 1, "Consolidated item must remain in place with empty JSON `{}`")
        let afterClear = backend.storedItem(
            service: HostSecretVaultStore.service,
            account: HostSecretVaultStore.account
        )
        precondition(afterClear?.itemID == originalItemID, "Item identity (ACL) must survive updates and full clear")
        precondition(defaults.bool(forKey: HostSecretVaultStore.DefaultsKey.hasAnySaved) == false)

        // Subsequent launch after clearing all secrets must perform 0 Keychain reads!
        let readsAfterClear = backend.copyMatchingDataCalls
        let postClearLaunch = HostSecretVaultStore(backend: backend, userDefaults: defaults)
        precondition(postClearLaunch.loadTmdbToken() == nil)
        precondition(backend.copyMatchingDataCalls == readsAfterClear, "Expected 0 reads when hasAnySaved == false")
    }

    private static func testLegacyMigrationConsolidatesAndDeletesLegacyEntries() throws {
        let backend = InMemoryHostKeychainBackend()
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var legacyNotify = NotifyChannelConfig()
        legacyNotify.webhookURL = "https://example.com/hook"
        let notifyData = try JSONEncoder().encode(legacyNotify)

        backend.seedItem(service: "dev.lightisle.tmdb", account: "api-token", data: Data("legacy-tmdb".utf8))
        backend.seedItem(service: "dev.lightisle.notify", account: "channels", data: notifyData)
        backend.seedItem(service: "dev.lightisle.tunnel", account: "manual-run-token", data: Data("legacy-run".utf8))

        let store = HostSecretVaultStore(backend: backend, userDefaults: defaults)
        precondition(store.loadTmdbToken() == "legacy-tmdb")
        precondition(store.loadTiandituKey() == nil)
        precondition(store.loadNotifyChannels()?.webhookURL == "https://example.com/hook")
        precondition(store.loadTunnelAPIToken() == nil)
        precondition(store.loadTunnelManualRunToken() == "legacy-run")

        // Only the 3 existing legacy entries should have had `kSecReturnData` reads!
        precondition(backend.copyMatchingDataCalls == 3, "Only existing legacy items should trigger data reads")
        precondition(backend.deleteCalls == 3, "All 3 migrated legacy items must be cleaned up")
        precondition(backend.itemCount == 1, "Only the single unified item should remain after migration")
        precondition(defaults.bool(forKey: HostSecretVaultStore.DefaultsKey.migratedV1) == true)
        precondition(defaults.bool(forKey: HostSecretVaultStore.DefaultsKey.hasAnySaved) == true)
    }

    private static func testLegacyMigrationUserCancelPreservesUnmigratedItems() throws {
        let backend = InMemoryHostKeychainBackend()
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        backend.seedItem(service: "dev.lightisle.tmdb", account: "api-token", data: Data("keep-tmdb".utf8))
        backend.seedItem(service: "dev.lightisle.tianditu", account: "api-key", data: Data("keep-map".utf8))

        // Simulate user clicking "Deny / Cancel" when macOS asks to read `dev.lightisle.tianditu` data.
        backend.forcedCopyMatchingStatus = { service, _, returnsData in
            if returnsData && service == "dev.lightisle.tianditu" {
                return errSecUserCanceled
            }
            return nil
        }

        let store = HostSecretVaultStore(backend: backend, userDefaults: defaults)
        precondition(store.loadTmdbToken() == "keep-tmdb")
        precondition(store.loadTiandituKey() == nil)
        precondition(
            defaults.bool(forKey: HostSecretVaultStore.DefaultsKey.migratedV1) == false,
            "migratedV1 must stay false when user cancels a legacy read"
        )
        precondition(
            backend.storedItem(service: "dev.lightisle.tianditu", account: "api-key") != nil,
            "Unmigrated legacy item must never be deleted on user cancel"
        )

        // Next launch after user allows access completes the remaining migration cleanly.
        backend.forcedCopyMatchingStatus = nil
        let retryStore = HostSecretVaultStore(backend: backend, userDefaults: defaults)
        precondition(retryStore.loadTmdbToken() == "keep-tmdb")
        precondition(retryStore.loadTiandituKey() == "keep-map")
        precondition(defaults.bool(forKey: HostSecretVaultStore.DefaultsKey.migratedV1) == true)
        precondition(backend.storedItem(service: "dev.lightisle.tianditu", account: "api-key") == nil)
        precondition(backend.itemCount == 1)
    }

    private static func testFacadeCompatibilityWrappers() throws {
        let backend = InMemoryHostKeychainBackend()
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: HostSecretVaultStore.DefaultsKey.migratedV1)

        let store = HostSecretVaultStore(backend: backend, userDefaults: defaults)
        try HostSecretVault.withTestingStore(store) {
            try TmdbSecretVault.save("facade-tmdb")
            try MapSecretVault.save("facade-map")
            try TunnelSecretVault.save("facade-cf-api")
            try TunnelSecretVault.saveManualRunToken("facade-cf-run")

            precondition(TmdbSecretVault.load() == "facade-tmdb")
            precondition(MapSecretVault.load() == "facade-map")
            precondition(TunnelSecretVault.load() == "facade-cf-api")
            precondition(TunnelSecretVault.loadManualRunToken() == "facade-cf-run")

            TmdbSecretVault.remove()
            try MapSecretVault.remove()
            try TunnelSecretVault.remove()
            try TunnelSecretVault.removeManualRunToken()

            precondition(TmdbSecretVault.load() == nil)
            precondition(MapSecretVault.load() == nil)
            precondition(TunnelSecretVault.load() == nil)
            precondition(TunnelSecretVault.loadManualRunToken() == nil)
            precondition(backend.deleteCalls == 0)
        }
    }
}
