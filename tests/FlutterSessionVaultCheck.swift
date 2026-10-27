import Foundation

/// Only touches a random test service; never reads the application's account.
@main
struct FlutterSessionVaultCheck {
    static func main() throws {
        let vault = KeychainSessionVault(service: "top.lengsu.lightisle.test." + UUID().uuidString)
        defer { try? vault.clear() }
        let initial = try vault.read()
        precondition(initial == nil)
        try vault.write("{\"fixture\":\"first\"}")
        let first = try vault.read()
        precondition(first == "{\"fixture\":\"first\"}")
        try vault.write("{\"fixture\":\"updated\"}")
        let updated = try vault.read()
        precondition(updated == "{\"fixture\":\"updated\"}")
        try vault.clear()
        let cleared = try vault.read()
        precondition(cleared == nil)
        print("Isolated Flutter Keychain read/write/update/clear passed")
    }
}
