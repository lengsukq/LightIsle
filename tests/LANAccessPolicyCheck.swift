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
        defaults.set(false, forKey: LANAccessPolicy.enabledKey)
        precondition(!LANAccessPolicy.isPreferred(defaults: defaults))
        precondition(!LANAccessPolicy.shouldAutoEnable(
            coreOnline: true, administratorReady: true,
            alreadyListening: false, changePending: false, defaults: defaults))
        defaults.set(true, forKey: LANAccessPolicy.enabledKey)
        precondition(LANAccessPolicy.isPreferred(defaults: defaults))
        print("PASS: default LAN HTTP, explicit HTTPS preference and persistent manual disable")
    }
}
