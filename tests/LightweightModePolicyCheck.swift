import Foundation

@main
struct LightweightModePolicyCheck {
    static func main() {
        let key = LightweightModePolicy.autoOnLockKey
        let suite = "dev.lightisle.lightweight-policy-regression"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("UserDefaults suite unavailable")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removeObject(forKey: key)
        precondition(LightweightModePolicy.autoOnLock(defaults: defaults))
        defaults.set(false, forKey: key)
        precondition(!LightweightModePolicy.autoOnLock(defaults: defaults))
        defaults.set(true, forKey: key)
        precondition(LightweightModePolicy.autoOnLock(defaults: defaults))
        precondition(LightweightModePolicy.shouldEnterOnLock(automatic: true, alreadyLightweight: false))
        precondition(!LightweightModePolicy.shouldEnterOnLock(automatic: false, alreadyLightweight: false))
        precondition(!LightweightModePolicy.shouldEnterOnLock(automatic: true, alreadyLightweight: true))
        precondition(LightweightModePolicy.pollingSeconds(isLightweight: true) >
                     LightweightModePolicy.pollingSeconds(isLightweight: false))
        precondition(LightweightModePolicy.pollingSeconds(isLightweight: false, windowVisible: false) == 60)
        precondition(LightweightModePolicy.pollingSeconds(isLightweight: false, windowVisible: true) == 3)
        precondition(LightweightModePolicy.pollingSeconds(isLightweight: true, windowVisible: true) == 60)
        print("PASS: lightweight lock preference, manual override and polling policy")
    }
}
