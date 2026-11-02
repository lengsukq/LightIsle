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
}
