import Foundation

@main
struct CoreLifecycleSignalCheck {
    static func main() {
        let ready = CoreLifecycleSignal.decode("LIGHTISLE_READY http://127.0.0.1:16666")
        guard case .ready(let url)? = ready, url.port == 16666 else {
            fatalError("Ready URL must parse as loopback HTTP")
        }
        guard CoreLifecycleSignal.decode("LIGHTISLE_READY http://example.com:16666") == nil,
              CoreLifecycleSignal.decode("LIGHTISLE_READY https://127.0.0.1:16666") == nil,
              CoreLifecycleSignal.decode("LIGHTISLE_READY garbage") == nil else {
            fatalError("Must reject non-loopback and malformed Core URLs")
        }
        guard CoreLifecycleSignal.decode("LIGHTISLE_REMOTE_OFF") == .remoteOff,
              CoreLifecycleSignal.decode("LIGHTISLE_REMOTE_ERROR bind_failed") == .remoteError("bind_failed"),
              CoreLifecycleSignal.decode("LIGHTISLE_UNKNOWN") == nil else {
            fatalError("Remote lifecycle status must be preserved")
        }
        print("PASS: lifecycle event decoder accepts only trusted Core loopback READY messages")
    }
}
