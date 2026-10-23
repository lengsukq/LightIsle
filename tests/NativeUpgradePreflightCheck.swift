import Foundation
import SQLite3

@main
struct NativeUpgradePreflightCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lightisle-upgrade-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = NativeUpgradePreflight.inspect(root)
        precondition(!missing.canProceedWithManualUpgrade, "missing accounts DB must block upgrade")

        let file = root.appendingPathComponent("accounts.sqlite")
        var db: OpaquePointer?
        precondition(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { if let db { sqlite3_close(db) } }
        precondition(sqlite3_exec(db, "CREATE TABLE users(id INTEGER PRIMARY KEY); INSERT INTO users VALUES(1)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        db = nil
        let original = try Data(contentsOf: file)
        let good = NativeUpgradePreflight.inspect(root)
        precondition(good.canProceedWithManualUpgrade, "healthy accounts SQLite not accepted")
        let afterCheck = try Data(contentsOf: file)
        precondition(afterCheck == original, "preflight changed the SQLite database")

        let symlink = root.appendingPathComponent("other.sqlite")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        let unsafe = NativeUpgradePreflight.inspect(root)
        precondition(!unsafe.canProceedWithManualUpgrade, "database symlink must block upgrade")
        try FileManager.default.removeItem(at: symlink)

        try Data("not a SQLite DB".utf8).write(to: file, options: .atomic)
        let corrupted = NativeUpgradePreflight.inspect(root)
        precondition(!corrupted.canProceedWithManualUpgrade, "corrupt database must block upgrade")
        let afterCorruptionCheck = try Data(contentsOf: file)
        precondition(afterCorruptionCheck == Data("not a SQLite DB".utf8), "preflight repaired without consent")
        print("PASS: native upgrade preflight read-only, missing/invalid database refusal and symlink isolation")
    }
}
