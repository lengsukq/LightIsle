import Foundation

@main
struct ServicePersistencePolicyCheck {
    static func main() {
        let suite = "dev.lightisle.service-persistence-policy-regression"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("UserDefaults suite unavailable")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        // 1. FRP persistence defaults to off and remembers start/stop across relaunches.
        precondition(!FRPPersistencePolicy.isPreferred(defaults: defaults))
        precondition(!FRPPersistencePolicy.shouldAutoStart(
            coreOnline: true,
            installed: true,
            status: "stopped",
            proxyCount: 2,
            alreadyAttemptedInSession: false,
            defaults: defaults
        ))

        FRPPersistencePolicy.rememberEnabled(true, defaults: defaults)
        let relaunched = UserDefaults(suiteName: suite)!
        precondition(FRPPersistencePolicy.isPreferred(defaults: relaunched))
        precondition(FRPPersistencePolicy.shouldAutoStart(
            coreOnline: true,
            installed: true,
            status: "stopped",
            proxyCount: 1,
            alreadyAttemptedInSession: false,
            defaults: relaunched
        ))
        // Must not auto-start if not installed, zero proxies, already running, or already attempted.
        precondition(!FRPPersistencePolicy.shouldAutoStart(
            coreOnline: true,
            installed: false,
            status: "stopped",
            proxyCount: 1,
            alreadyAttemptedInSession: false,
            defaults: relaunched
        ))
        precondition(!FRPPersistencePolicy.shouldAutoStart(
            coreOnline: true,
            installed: true,
            status: "stopped",
            proxyCount: 0,
            alreadyAttemptedInSession: false,
            defaults: relaunched
        ))
        precondition(!FRPPersistencePolicy.shouldAutoStart(
            coreOnline: true,
            installed: true,
            status: "running",
            proxyCount: 1,
            alreadyAttemptedInSession: false,
            defaults: relaunched
        ))
        precondition(!FRPPersistencePolicy.shouldAutoStart(
            coreOnline: true,
            installed: true,
            status: "stopped",
            proxyCount: 1,
            alreadyAttemptedInSession: true,
            defaults: relaunched
        ))

        FRPPersistencePolicy.rememberEnabled(false, defaults: defaults)
        precondition(!FRPPersistencePolicy.isPreferred(defaults: relaunched))
        precondition(!FRPPersistencePolicy.shouldAutoStart(
            coreOnline: true,
            installed: true,
            status: "stopped",
            proxyCount: 1,
            alreadyAttemptedInSession: false,
            defaults: relaunched
        ))

        // 2. Cloudflare Tunnel persistence covers off, quick, named, and manual modes.
        precondition(TunnelPersistencePolicy.preferredMode(defaults: defaults) == .off)
        precondition(!TunnelPersistencePolicy.shouldAutoRestore(
            coreOnline: true,
            binaryFound: true,
            status: "stopped",
            alreadyAttemptedInSession: false,
            defaults: defaults
        ))

        TunnelPersistencePolicy.recordQuickStart(defaults: defaults)
        precondition(TunnelPersistencePolicy.preferredMode(defaults: relaunched) == .quick)
        precondition(TunnelPersistencePolicy.shouldAutoRestore(
            coreOnline: true,
            binaryFound: true,
            status: "stopped",
            alreadyAttemptedInSession: false,
            defaults: relaunched
        ))
        precondition(!TunnelPersistencePolicy.shouldAutoRestore(
            coreOnline: true,
            binaryFound: false,
            status: "stopped",
            alreadyAttemptedInSession: false,
            defaults: relaunched
        ))

        TunnelPersistencePolicy.recordNamedStart(
            accountID: "acc-1",
            tunnelID: "tun-1",
            tunnelName: "Home-NAS",
            defaults: defaults
        )
        let target = TunnelPersistencePolicy.preferredTarget(defaults: relaunched)
        precondition(target == TunnelPersistenceTarget(
            mode: .named,
            accountID: "acc-1",
            tunnelID: "tun-1",
            tunnelName: "Home-NAS"
        ))
        // Named mode waits until API token is configured/validated in Core.
        precondition(!TunnelPersistencePolicy.shouldAutoRestore(
            coreOnline: true,
            binaryFound: true,
            status: "stopped",
            alreadyAttemptedInSession: false,
            apiConfigured: false,
            defaults: relaunched
        ))
        precondition(TunnelPersistencePolicy.shouldAutoRestore(
            coreOnline: true,
            binaryFound: true,
            status: "stopped",
            alreadyAttemptedInSession: false,
            apiConfigured: true,
            defaults: relaunched
        ))

        // Stopping disables auto-restore while preserving the selected tunnel ID for the UI picker.
        TunnelPersistencePolicy.recordStop(defaults: defaults)
        precondition(TunnelPersistencePolicy.preferredMode(defaults: relaunched) == .off)
        precondition(TunnelPersistencePolicy.selectedTunnelID(defaults: relaunched) == "tun-1")
        precondition(!TunnelPersistencePolicy.shouldAutoRestore(
            coreOnline: true,
            binaryFound: true,
            status: "stopped",
            alreadyAttemptedInSession: false,
            apiConfigured: true,
            defaults: relaunched
        ))

        // Manual token mode requires manualTokenAvailable.
        TunnelPersistencePolicy.recordManualStart(defaults: defaults)
        precondition(TunnelPersistencePolicy.preferredMode(defaults: relaunched) == .manual)
        precondition(!TunnelPersistencePolicy.shouldAutoRestore(
            coreOnline: true,
            binaryFound: true,
            status: "stopped",
            alreadyAttemptedInSession: false,
            manualTokenAvailable: false,
            defaults: relaunched
        ))
        precondition(TunnelPersistencePolicy.shouldAutoRestore(
            coreOnline: true,
            binaryFound: true,
            status: "stopped",
            alreadyAttemptedInSession: false,
            manualTokenAvailable: true,
            defaults: relaunched
        ))

        // A tunnel that is already carrying traffic is left alone even though the
        // persisted intent still asks for auto-restore, so a lagging local status
        // cannot cause a duplicate start.
        precondition(!TunnelPersistencePolicy.shouldAutoRestore(
            coreOnline: true,
            tunnelConnectionActive: true,
            binaryFound: true,
            status: "stopped",
            alreadyAttemptedInSession: false,
            manualTokenAvailable: true,
            defaults: relaunched
        ))

        // Forgetting API credentials clears named selection without breaking manual mode if active,
        // and resets named mode to off when named was active.
        TunnelPersistencePolicy.recordNamedStart(
            accountID: "acc-1",
            tunnelID: "tun-1",
            tunnelName: "Home-NAS",
            defaults: defaults
        )
        TunnelPersistencePolicy.clearNamedCredentials(defaults: defaults)
        precondition(TunnelPersistencePolicy.preferredMode(defaults: relaunched) == .off)
        precondition(TunnelPersistencePolicy.selectedTunnelID(defaults: relaunched) == nil)
        print("PASS: FRP and Cloudflare Tunnel restart persistence and single-shot auto-restore policy")
    }
}
