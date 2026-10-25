import Foundation

@main
struct TunnelWireCodecCheck {
    static func main() throws {
        let command = try TunnelWireCodec.apiCommand(operation: "configure",
            payload: ["apiToken": "not-a-real-credential-123"])
        precondition(command.hasPrefix("tunnel api configure "))
        let encoded = String(command.dropFirst("tunnel api configure ".count))
        let parsed = TunnelWireCodec.decodeAPI(encoded)
        precondition(parsed?["apiToken"] as? String == "not-a-real-credential-123")
        precondition(!command.contains("not-a-real-credential-123"))
        precondition(TunnelWireCodec.decodeAPI("!!!") == nil)
        precondition(TunnelWireCodec.decodeAPI("bnVsbA") == nil)
        let message = Data("request_failed".utf8).base64EncodedString()
        precondition(TunnelWireCodec.decodeError(message) == "request_failed")

        let manual = try TunnelWireCodec.manualTokenCommand("   0123456789abcdef   ")
        precondition(manual.hasPrefix("tunnel run "))
        let payload = TunnelWireCodec.decodeAPI(String(manual.dropFirst("tunnel run ".count)))
        precondition(payload?["token"] as? String == "0123456789abcdef")

        do {
            _ = try TunnelWireCodec.apiCommand(operation: "configure\nmalicious", payload: [:])
            fatalError("unexpected acceptance of injected operation")
        } catch TunnelWireError.invalidOperation {}
        do {
            _ = try TunnelWireCodec.manualTokenCommand("short")
            fatalError("unexpected acceptance of invalid manual token")
        } catch TunnelWireError.invalidRequest {}
        do {
            _ = try TunnelWireCodec.apiCommand(operation: "configure", payload: ["apiToken": String(repeating: "X", count: 20_000)])
            fatalError("oversize payload was accepted")
        } catch TunnelWireError.invalidRequest {}
        print("PASS: tunnel commands are bounded and IPC responses decode without leaking tokens")
    }
}
