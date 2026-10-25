import Foundation

@main
struct NativeServicePresenceCheck {
    @MainActor
    static func main() {
        let port = NativeServicePresenceCoordinator.bonjourPort
        precondition(port(true, "https://nas.local:16666") == 16666)
        precondition(port(true, "https://nas.local:443") == 443)
        precondition(port(false, "https://nas.local:16666") == nil)
        precondition(port(true, "http://nas.local:16666") == nil)
        precondition(port(true, "https://nas.local") == nil)
        precondition(port(true, "https://nas.local:0") == nil)
        precondition(port(true, "not-a-url") == nil)
        precondition(port(true, nil) == nil)
        print("PASS: native service presence only advertises an online HTTPS port")
    }
}
