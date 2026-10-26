import Foundation

/// Owns the two host-wide effects of an online Core process: preventing idle
/// sleep when explicitly configured and advertising the selected LAN listener.
/// Neither setting starts a listener or grants access to any shared directory.
@MainActor
final class NativeServicePresenceCoordinator {
    var onBonjourStatusChange: ((String) -> Void)?

    private var sleepActivity: NSObjectProtocol?
    private lazy var bonjourPublisher: BonjourPublisher = {
        let publisher = BonjourPublisher()
        publisher.onStatusChange = { [weak self] status in
            self?.onBonjourStatusChange?(status)
        }
        return publisher
    }()

    func updateSleepPolicy(serviceOnline: Bool, keepAwake: Bool) {
        let preventIdleSleep = serviceOnline && keepAwake
        if preventIdleSleep && sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "LightIsle is serving the personal NAS"
            )
        } else if !preventIdleSleep, let existing = sleepActivity {
            ProcessInfo.processInfo.endActivity(existing)
            sleepActivity = nil
        }
    }

    func updateBonjour(serviceOnline: Bool, remoteAddress: String?) {
        guard let port = Self.bonjourPort(serviceOnline: serviceOnline, remoteAddress: remoteAddress),
              let scheme = remoteAddress.flatMap({ URL(string: $0)?.scheme }) else {
            bonjourPublisher.stop()
            return
        }
        bonjourPublisher.update(port: port, scheme: scheme)
    }

    static func bonjourPort(serviceOnline: Bool, remoteAddress: String?) -> Int? {
        guard serviceOnline, let remoteAddress,
              let url = URL(string: remoteAddress), ["https", "http"].contains(url.scheme ?? ""),
              let port = url.port, (1...65535).contains(port) else { return nil }
        return port
    }
}
