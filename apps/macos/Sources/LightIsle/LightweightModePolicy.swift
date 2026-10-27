import Foundation

/// Lightweight mode is a UI lifecycle choice, not a change to the NAS Core.
/// Keep automatic screen locking separate from the existing login-item setting.
enum LightweightModePolicy {
    static let autoOnLockKey = "lightisle.lightweight.autoOnLock"
    static let normalPollingSeconds: Double = 3
    static let lightweightPollingSeconds: Double = 60

    static func autoOnLock(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: autoOnLockKey) as? Bool) ?? true
    }

    static func shouldEnterOnLock(automatic: Bool, alreadyLightweight: Bool) -> Bool {
        automatic && !alreadyLightweight
    }

    static func pollingSeconds(isLightweight: Bool) -> Double {
        isLightweight ? lightweightPollingSeconds : normalPollingSeconds
    }
}
