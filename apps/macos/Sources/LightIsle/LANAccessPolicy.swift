import Foundation

enum LANAccessPolicy {
    static let enabledKey = "lightisle.remoteEnabled"
    static let useHTTPKey = "lightisle.allowLANHTTP"

    // Familiar home-LAN HTTP is the zero-configuration default. Preserve an
    // explicitly selected HTTPS mode across relaunches.
    static func prefersHTTP(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: useHTTPKey) as? Bool) ?? true
    }

    static func isPreferred(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: enabledKey) as? Bool) ?? true
    }

    static func rememberEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    static func rememberHTTP(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: useHTTPKey)
    }

    static func shouldAutoEnable(
        coreOnline: Bool,
        administratorReady: Bool,
        alreadyListening: Bool,
        changePending: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        coreOnline && administratorReady && !alreadyListening && !changePending &&
            isPreferred(defaults: defaults)
    }

    // A laptop may launch the NAS before Wi-Fi or Ethernet acquires its
    // private address. Retry only this transient failure: a bound port,
    // invalid configuration or certificate error requires user attention,
    // and an explicit user "off" must never be silently overridden.
    static func canRetryAfterNetworkChange(_ error: String) -> Bool {
        error.contains("没有可用的局域网私有 IPv4 地址") ||
            error.contains("can't assign requested address") ||
            error.contains("Cannot assign requested address")
    }
}
