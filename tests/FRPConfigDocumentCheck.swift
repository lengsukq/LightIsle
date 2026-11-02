import Foundation

@main
struct FRPConfigDocumentCheck {
    static func main() throws {
        let source = """
        # Existing comments must not disappear
        serverAddr = "frps.example.com"
        serverPort = 7000
        auth.method = "token"
        auth.token = "old#token"
        transport.tls.enable = true

        [[proxies]]
        name = "ssh"
        type = "tcp"
        localIP = "127.0.0.1"
        localPort = 22
        remotePort = 6000
        transport.useEncryption = true

        [[proxies]]
        name = "site"
        type = "http"
        localIP = "127.0.0.1"
        localPort = 8080
        customDomains = ["a.example.com", "b.example.com"]

        [[proxies]]
        name = "advanced"
        type = "stcp"
        sk = "keep-me"
        """
        let original = try FRPConfigDocument(text: source)
        precondition(original.draft.serverAddress == "frps.example.com")
        precondition(original.draft.token == "old#token")
        precondition(original.draft.proxies.count == 2)
        precondition(original.draft.advancedProxyCount == 1)
        precondition(original.draft.proxies[1].domains == "a.example.com, b.example.com")
        var edited = original.draft
        edited.token = "new-token"
        edited.proxies[0].remotePort = "6001"
        edited.proxies.remove(at: 1)
        edited.proxies.append(FRPProxyDraft(name: "new-udp", type: "udp", localPort: "5353", remotePort: "15353"))
        let rendered = try original.render(edited)
        precondition(rendered.contains("# Existing comments must not disappear"))
        precondition(rendered.contains("transport.tls.enable = true"))
        precondition(rendered.contains("transport.useEncryption = true"))
        precondition(rendered.contains("remotePort = 6001"))
        precondition(rendered.contains("name = \"new-udp\""))
        precondition(rendered.contains("sk = \"keep-me\""))
        precondition(!rendered.contains("customDomains ="))
        let reopened = try FRPConfigDocument(text: rendered)
        precondition(reopened.draft.proxies.count == 2)
        precondition(reopened.draft.advancedProxyCount == 1)
        precondition(reopened.draft.token == "new-token")

        var invalid = edited
        invalid.token = ""
        do {
            _ = try original.render(invalid)
            fatalError("Empty token must be rejected")
        } catch FRPConfigIssue.invalid { }
        do {
            _ = try FRPConfigDocument(text: """
            serverAddr = "frps.example.com"
            serverPort = 7000
            [auth]
            method = "oidc"
            """)
            fatalError("Unsupported auth modes must not be silently replaced")
        } catch FRPConfigIssue.invalid { }
        do {
            _ = try FRPConfigDocument(text: """
            [[proxies]]
            name = "plugin"
            type = "tcp"
            [proxies.plugin]
            type = "http2https"
            """)
            fatalError("Nested proxy sections must not be silently re-parented")
        } catch FRPConfigIssue.invalid { }
        var colliding = edited
        colliding.proxies[0].name = "advanced"
        do {
            _ = try original.render(colliding)
            fatalError("Duplicate names against preserved advanced rules must be rejected")
        } catch FRPConfigIssue.invalid { }
        invalid = edited
        invalid.proxies[0].localPort = "65536"
        do {
            _ = try original.render(invalid)
            fatalError("Invalid local port must be rejected")
        } catch FRPConfigIssue.invalid { }

        let authTable = try FRPConfigDocument(text: """
        serverAddr = "frps.local"
        serverPort = 7000
        [auth]
        method = "token"
        token = "old"
        """)
        var authEdited = authTable.draft
        authEdited.token = "updated"
        let authOut = try authTable.render(authEdited)
        precondition(authOut.contains("token = \"updated\""))
        precondition(!authOut.contains("auth.token ="))

        do {
            _ = try FRPConfigDocument(text: """
            serverAddr = "first"
            serverAddr = "second"
            serverPort = 7000
            """)
            fatalError("Ambiguous duplicate server field must not be editable")
        } catch FRPConfigIssue.invalid { }
        print("PASS: FRP visual TOML preserve/validate/multi-proxy/auth-table checks")
    }
}
