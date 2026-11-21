import Foundation

/// Isolated regression checks for `ClientVaultStore` and `ClientVaultPayload`
/// in `apps/flutter/shared/SessionVault.swift`. Uses an in-memory
/// `VaultItemStoring` fake and ephemeral `UserDefaults` suites so it never
/// touches or prompts the developer's real macOS login Keychain.
@main
struct FlutterSessionVaultCheck {
    private final class InMemoryVaultItem: VaultItemStoring {
        private unowned let box: StorageBox
        private let key: String

        init(box: StorageBox, key: String) {
            self.box = box
            self.key = key
        }

        func existsAttributesOnly() throws -> Bool {
            box.existsCalls += 1
            return box.items[key] != nil
        }

        func readData() throws -> Data? {
            box.readCalls += 1
            return box.items[key]
        }

        func upsertData(_ data: Data) throws {
            box.upsertCalls += 1
            box.items[key] = data
        }

        func deleteItem() throws {
            box.deleteCalls += 1
            box.items.removeValue(forKey: key)
        }
    }

    private final class StorageBox {
        var items: [String: Data] = [:]
        var existsCalls = 0
        var readCalls = 0
        var upsertCalls = 0
        var deleteCalls = 0

        func factory() -> (String, String) -> VaultItemStoring {
            { service, account in
                InMemoryVaultItem(box: self, key: "\(service)::\(account)")
            }
        }
    }

    private static func makeDefaults() -> (UserDefaults, String) {
        let suite = "top.lengsu.lightisle.tests.session-vault.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    static func main() throws {
        try testEmptyMigratedStateMakesZeroVaultQueries()
        try testFirstCleanStartupProbesAttributesOnly()
        try testConsolidatedMultiSlotCacheAndInPlaceClear()
        try testLegacyMigrationMergesAndDeletesOldItems()
        try testOversizedAndMalformedRejection()
        print("PASS: ClientVaultStore isolation, caching, in-place clear, legacy migration, and bounds checks")
    }

    private static func testEmptyMigratedStateMakesZeroVaultQueries() throws {
        let box = StorageBox()
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ClientVaultStore.migratedV1Key)
        defaults.set(false, forKey: ClientVaultStore.hasAnySavedKey)

        let store = ClientVaultStore(baseService: "test.client", userDefaults: defaults, itemFactory: box.factory())
        for slot in ClientVaultSlot.allCases {
            let value = try store.read(slot: slot)
            precondition(value == nil)
        }
        try store.clear(slot: .session)
        precondition(box.existsCalls == 0 && box.readCalls == 0 && box.upsertCalls == 0 && box.deleteCalls == 0)
    }

    private static func testFirstCleanStartupProbesAttributesOnly() throws {
        let box = StorageBox()
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ClientVaultStore(baseService: "test.client", userDefaults: defaults, itemFactory: box.factory())
        let initialSession = try store.read(slot: .session)
        precondition(initialSession == nil)
        precondition(box.existsCalls == 4, "Expected 1 unified + 3 legacy attribute probes")
        precondition(box.readCalls == 0, "Clean startup probe must not read item data")
        precondition(defaults.bool(forKey: ClientVaultStore.migratedV1Key) == true)
        precondition(defaults.bool(forKey: ClientVaultStore.hasAnySavedKey) == false)

        let secondLaunch = ClientVaultStore(baseService: "test.client", userDefaults: defaults, itemFactory: box.factory())
        let secondDav = try secondLaunch.read(slot: .davSecrets)
        precondition(secondDav == nil)
        precondition(box.existsCalls == 4 && box.readCalls == 0)
    }

    private static func testConsolidatedMultiSlotCacheAndInPlaceClear() throws {
        let box = StorageBox()
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ClientVaultStore.migratedV1Key)
        defaults.set(false, forKey: ClientVaultStore.hasAnySavedKey)

        let store = ClientVaultStore(baseService: "test.client", userDefaults: defaults, itemFactory: box.factory())
        try store.write("{\"token\":\"s1\"}", to: .session)
        try store.write("{\"dav\":\"d1\"}", to: .davSecrets)
        try store.write("[{\"user\":\"u1\"}]", to: .loginHistory)

        precondition(box.items.count == 1 && box.items["test.client.vault-v1::client-state"] != nil)
        precondition(box.upsertCalls == 3)
        precondition(defaults.bool(forKey: ClientVaultStore.hasAnySavedKey) == true)

        // Writing the exact same value should be a no-op.
        try store.write("{\"token\":\"s1\"}", to: .session)
        precondition(box.upsertCalls == 3)

        // Relaunch reads the consolidated envelope once and serves subsequent reads from memory.
        let relaunched = ClientVaultStore(baseService: "test.client", userDefaults: defaults, itemFactory: box.factory())
        let session = try relaunched.read(slot: .session)
        let dav = try relaunched.read(slot: .davSecrets)
        let history = try relaunched.read(slot: .loginHistory)
        precondition(session == "{\"token\":\"s1\"}")
        precondition(dav == "{\"dav\":\"d1\"}")
        precondition(history == "[{\"user\":\"u1\"}]")
        precondition(box.readCalls == 1)

        // Clearing all slots updates in place without deleting the Keychain ACL item.
        try relaunched.clear(slot: .session)
        try relaunched.clear(slot: .davSecrets)
        try relaunched.clear(slot: .loginHistory)
        precondition(box.deleteCalls == 0)
        precondition(box.items["test.client.vault-v1::client-state"] != nil)
        precondition(defaults.bool(forKey: ClientVaultStore.hasAnySavedKey) == false)
    }

    private static func testLegacyMigrationMergesAndDeletesOldItems() throws {
        let box = StorageBox()
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let existing = try JSONEncoder().encode(ClientVaultPayload(version: 1, session: "new-session", davSecrets: nil, loginHistory: nil))
        box.items["test.client.vault-v1::client-state"] = existing
        box.items["test.client.login-session::active-session"] = Data("old-session".utf8)
        box.items["test.client.dav-local-secrets::active-session"] = Data("old-dav".utf8)
        box.items["test.client.login-history::active-session"] = Data("old-history".utf8)

        let store = ClientVaultStore(baseService: "test.client", userDefaults: defaults, itemFactory: box.factory())
        let session = try store.read(slot: .session)
        let dav = try store.read(slot: .davSecrets)
        let history = try store.read(slot: .loginHistory)
        precondition(session == "new-session", "Existing v1 slot must win over legacy slot")
        precondition(dav == "old-dav")
        precondition(history == "old-history")
        precondition(box.deleteCalls == 3)
        precondition(box.items.count == 1)
    }

    private static func testOversizedAndMalformedRejection() throws {
        let box = StorageBox()
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ClientVaultStore.migratedV1Key)
        defaults.set(false, forKey: ClientVaultStore.hasAnySavedKey)

        let store = ClientVaultStore(baseService: "test.client", userDefaults: defaults, itemFactory: box.factory())
        let oversized = String(repeating: "x", count: ClientVaultStore.maxSlotBytes + 1)
        do {
            try store.write(oversized, to: .session)
            preconditionFailure("Expected oversized slot rejection")
        } catch {}

        box.items["test.client.vault-v1::client-state"] = Data("not-json".utf8)
        defaults.set(true, forKey: ClientVaultStore.hasAnySavedKey)
        let brokenStore = ClientVaultStore(baseService: "test.client", userDefaults: defaults, itemFactory: box.factory())
        do {
            _ = try brokenStore.read(slot: .session)
            preconditionFailure("Expected malformed envelope rejection")
        } catch {}
    }
}
