import Foundation

/// Persists the administrator's explicit FRP start/stop intent across app and
/// Core restarts. Unlike LAN access, FRP defaults to off until the user
/// installs frpc, configures a valid proxy and clicks Start.
enum FRPPersistencePolicy {
    static let enabledKey = "lightisle.frp.enabled"

    static func isPreferred(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return false }
        return defaults.bool(forKey: enabledKey)
    }

    static func rememberEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    /// Auto-start runs at most once per Core generation and only when the
    /// local frpc binary is installed, currently stopped and has at least one
    /// configured proxy rule. Config or server errors surface without looping.
    static func shouldAutoStart(
        coreOnline: Bool,
        installed: Bool,
        status: String,
        proxyCount: Int?,
        alreadyAttemptedInSession: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard coreOnline, !alreadyAttemptedInSession else { return false }
        guard isPreferred(defaults: defaults) else { return false }
        guard installed, status == "stopped" else { return false }
        return (proxyCount ?? 0) > 0
    }
}

enum TunnelPersistenceMode: String, Equatable {
    case off
    case quick
    case named
    case manual

    var summaryLabel: String {
        switch self {
        case .off: return "已关闭自动恢复"
        case .quick: return "重启后自动恢复：免费快速隧道"
        case .named: return "重启后自动恢复：命名隧道"
        case .manual: return "重启后自动恢复：手动 Token 隧道"
        }
    }
}

struct TunnelPersistenceTarget: Equatable {
    let mode: TunnelPersistenceMode
    let accountID: String
    let tunnelID: String
    let tunnelName: String
}

/// Persists the administrator's active Cloudflare Tunnel mode and selected
/// named tunnel across restarts so the tunnel resumes automatically when the
/// app or Core restarts.
enum TunnelPersistencePolicy {
    static let modeKey = "lightisle.tunnel.preferredMode"
    static let accountIDKey = "lightisle.tunnel.selectedAccountID"
    static let tunnelIDKey = "lightisle.tunnel.selectedTunnelID"
    static let tunnelNameKey = "lightisle.tunnel.selectedTunnelName"

    static func preferredMode(defaults: UserDefaults = .standard) -> TunnelPersistenceMode {
        guard let raw = defaults.string(forKey: modeKey),
              let mode = TunnelPersistenceMode(rawValue: raw) else {
            return .off
        }
        return mode
    }

    static func selectedAccountID(defaults: UserDefaults = .standard) -> String? {
        guard let value = defaults.string(forKey: accountIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func selectedTunnelID(defaults: UserDefaults = .standard) -> String? {
        guard let value = defaults.string(forKey: tunnelIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func selectedTunnelName(defaults: UserDefaults = .standard) -> String? {
        guard let value = defaults.string(forKey: tunnelNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func preferredTarget(defaults: UserDefaults = .standard) -> TunnelPersistenceTarget {
        TunnelPersistenceTarget(
            mode: preferredMode(defaults: defaults),
            accountID: selectedAccountID(defaults: defaults) ?? "",
            tunnelID: selectedTunnelID(defaults: defaults) ?? "",
            tunnelName: selectedTunnelName(defaults: defaults) ?? ""
        )
    }

    static func rememberSelectedTunnel(
        accountID: String?,
        tunnelID: String?,
        tunnelName: String?,
        defaults: UserDefaults = .standard
    ) {
        if let accountID, !accountID.isEmpty {
            defaults.set(accountID, forKey: accountIDKey)
        }
        if let tunnelID, !tunnelID.isEmpty {
            defaults.set(tunnelID, forKey: tunnelIDKey)
        } else {
            defaults.removeObject(forKey: tunnelIDKey)
        }
        if let tunnelName, !tunnelName.isEmpty {
            defaults.set(tunnelName, forKey: tunnelNameKey)
        } else if tunnelID == nil {
            defaults.removeObject(forKey: tunnelNameKey)
        }
    }

    static func recordQuickStart(defaults: UserDefaults = .standard) {
        defaults.set(TunnelPersistenceMode.quick.rawValue, forKey: modeKey)
    }

    static func recordNamedStart(
        accountID: String,
        tunnelID: String,
        tunnelName: String,
        defaults: UserDefaults = .standard
    ) {
        rememberSelectedTunnel(
            accountID: accountID,
            tunnelID: tunnelID,
            tunnelName: tunnelName,
            defaults: defaults
        )
        defaults.set(TunnelPersistenceMode.named.rawValue, forKey: modeKey)
    }

    static func recordManualStart(defaults: UserDefaults = .standard) {
        defaults.set(TunnelPersistenceMode.manual.rawValue, forKey: modeKey)
    }

    /// Stopping the tunnel disables auto-restore on next launch while keeping
    /// the last selected named tunnel ID so the picker selection stays stable.
    static func recordStop(defaults: UserDefaults = .standard) {
        defaults.set(TunnelPersistenceMode.off.rawValue, forKey: modeKey)
    }

    static func clearNamedCredentials(defaults: UserDefaults = .standard) {
        if preferredMode(defaults: defaults) == .named {
            defaults.set(TunnelPersistenceMode.off.rawValue, forKey: modeKey)
        }
        defaults.removeObject(forKey: accountIDKey)
        defaults.removeObject(forKey: tunnelIDKey)
        defaults.removeObject(forKey: tunnelNameKey)
    }

    static func shouldAutoRestore(
        coreOnline: Bool,
        // An already-running tunnel must not be started a second time; the
        // local status can lag behind the real Cloudflare connection.
        tunnelConnectionActive: Bool = false,
        binaryFound: Bool,
        status: String,
        alreadyAttemptedInSession: Bool,
        apiConfigured: Bool = false,
        manualTokenAvailable: Bool = false,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard coreOnline, !alreadyAttemptedInSession, !tunnelConnectionActive else { return false }
        guard binaryFound, status == "stopped" else { return false }
        let target = preferredTarget(defaults: defaults)
        switch target.mode {
        case .off:
            return false
        case .quick:
            return true
        case .named:
            return apiConfigured && !target.accountID.isEmpty && !target.tunnelID.isEmpty
        case .manual:
            return manualTokenAvailable
        }
    }
}
