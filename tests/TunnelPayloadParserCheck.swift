import Foundation
import Security

// TunnelSupport's Keychain helper shares VaultError with the full native app.
// Standalone parser tests supply the narrow error signature without loading UI.
enum VaultError: Error {
    case keychainError(OSStatus)
}

@main
struct TunnelPayloadParserCheck {
    static func main() {
        let snapshot = TunnelPayloadParser.parse([
            "operation": "configure",
            "accounts": [["id": "account-1", "name": "My account"]],
            "zones": [
                ["id": "zone-1", "name": "example.com", "status": "active"],
                ["id": "zone-2", "name": "unused.test", "status": "pending"]
            ],
            "tunnels": [[
                "id": "tunnel-1", "name": "Home", "status": "healthy",
                "conns_active": 2, "config_src": "cloudflare"
            ]],
            "config": ["ingress": [
                ["hostname": "nas.example.com", "service": "http://127.0.0.1:16666"],
            ]]
        ])
        precondition(snapshot.operation == "configure")
        precondition(snapshot.accounts?.first?.id == "account-1")
        precondition(snapshot.zones?.count == 1)
        precondition(snapshot.tunnels?.first?.remoteConfig == true)
        precondition(snapshot.ingress?.first?.hostname == "nas.example.com")
        precondition(!snapshot.deleted && !snapshot.forgotten)

        let revoked = TunnelPayloadParser.parse(["operation": "forget", "forgotten": true])
        precondition(revoked.forgotten && revoked.accounts == nil)
        let unrelated = TunnelPayloadParser.parse(["operation": "accounts", "accounts": []])
        precondition(unrelated.operation != "configure")
        let malformed = TunnelPayloadParser.parse(["tunnels": [["id": 99]], "accounts": "not-an-array"])
        precondition(malformed.tunnels == nil && malformed.accounts == nil)
        print("PASS: tunnel response parser isolates typed data and tags credential acknowledgements")
    }
}
