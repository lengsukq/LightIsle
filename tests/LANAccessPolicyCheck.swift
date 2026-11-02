import Foundation

@main
struct LANAccessPolicyCheck {
    static func main() {
        let suite = "dev.lightisle.lan-default-policy-regression"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("UserDefaults suite unavailable")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removeObject(forKey: LANAccessPolicy.enabledKey)
        defaults.removeObject(forKey: LANAccessPolicy.useHTTPKey)
        precondition(LANAccessPolicy.prefersHTTP(defaults: defaults))
        defaults.set(false, forKey: LANAccessPolicy.useHTTPKey)
        precondition(!LANAccessPolicy.prefersHTTP(defaults: defaults))
        defaults.set(true, forKey: LANAccessPolicy.useHTTPKey)
        precondition(LANAccessPolicy.prefersHTTP(defaults: defaults))
        defaults.removeObject(forKey: LANAccessPolicy.useHTTPKey)

        // Newly installed app: enabled only after authenticated setup and Core readiness.
        precondition(LANAccessPolicy.isPreferred(defaults: defaults))
        precondition(LANAccessPolicy.shouldAutoEnable(
            coreOnline: true, administratorReady: true,
            alreadyListening: false, changePending: false, defaults: defaults))
        precondition(!LANAccessPolicy.shouldAutoEnable(
            coreOnline: false, administratorReady: true,
            alreadyListening: false, changePending: false, defaults: defaults))
        precondition(!LANAccessPolicy.shouldAutoEnable(
            coreOnline: true, administratorReady: false,
            alreadyListening: false, changePending: false, defaults: defaults))
        precondition(!LANAccessPolicy.shouldAutoEnable(
            coreOnline: true, administratorReady: true,
            alreadyListening: true, changePending: false, defaults: defaults))
        precondition(!LANAccessPolicy.shouldAutoEnable(
            coreOnline: true, administratorReady: true,
            alreadyListening: false, changePending: true, defaults: defaults))

        // A manual off persists across the next launch.
        LANAccessPolicy.rememberEnabled(false, defaults: defaults)
        precondition(!LANAccessPolicy.isPreferred(defaults: defaults))
        // Reading from another UserDefaults instance simulates reopening the
        // app: the preference is stored, not inferred from the listener.
        let relaunchedDefaults = UserDefaults(suiteName: suite)!
        precondition(!LANAccessPolicy.isPreferred(defaults: relaunchedDefaults))
        precondition(!LANAccessPolicy.shouldAutoEnable(
            coreOnline: true, administratorReady: true,
            alreadyListening: false, changePending: false, defaults: relaunchedDefaults))
        LANAccessPolicy.rememberEnabled(true, defaults: defaults)
        precondition(LANAccessPolicy.isPreferred(defaults: defaults))
        precondition(LANAccessPolicy.isPreferred(defaults: relaunchedDefaults))
        precondition(LANAccessPolicy.shouldAutoEnable(
            coreOnline: true, administratorReady: true,
            alreadyListening: false, changePending: false, defaults: relaunchedDefaults))
        LANAccessPolicy.rememberHTTP(false, defaults: defaults)
        precondition(!LANAccessPolicy.prefersHTTP(defaults: relaunchedDefaults))
        LANAccessPolicy.rememberHTTP(true, defaults: defaults)
        precondition(LANAccessPolicy.prefersHTTP(defaults: relaunchedDefaults))

        precondition(LANAccessPolicy.canRetryAfterNetworkChange("没有可用的局域网私有 IPv4 地址"))
        precondition(LANAccessPolicy.canRetryAfterNetworkChange("Cannot assign requested address"))
        precondition(!LANAccessPolicy.canRetryAfterNetworkChange("address already in use"))
        precondition(!LANAccessPolicy.canRetryAfterNetworkChange("certificate invalid"))
        print("PASS: first-run LAN default, restart persistence, HTTP/HTTPS preference and transient retry")
    }
}
