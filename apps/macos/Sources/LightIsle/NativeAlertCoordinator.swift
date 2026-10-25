import Foundation

/// The wire payload emitted by Go Core's durable alert journal.
struct CorePersistentAlert: Decodable {
    let code: String
    let severity: String
    let message: String
    let active: Bool
    let acknowledged: Bool
}

/// Owns notification deduplication, alert code mapping and local delivery.
/// AppModel retains only the opt-in preference and the UI-visible error state.
@MainActor
final class NativeAlertCoordinator {
    private let delivery = NativeAlertDelivery()
    private var lastActiveCodes = Set<String>()

    func requestPermission() async -> Bool {
        await delivery.requestPermission()
    }

    func clear(key: String) {
        delivery.clear(key: key)
    }

    func deliverIfEnabled(_ enabled: Bool, key: String, title: String, message: String) {
        guard enabled else { return }
        delivery.deliver(key: key, title: title, description: message)
    }

    func checkLowDiskSpace(_ volumes: [HostVolume], enabled: Bool) {
        guard enabled else { return }
        for volume in volumes where !volume.readOnly && volume.total > 0 {
            let low = volume.free < 5 * 1024 * 1024 * 1024 ||
                Double(volume.free) / Double(volume.total) < 0.05
            let key = "disk-space:" + volume.mount
            if low {
                deliverIfEnabled(enabled, key: key, title: "轻屿磁盘空间不足",
                    message: "有存储卷剩余空间低于 5 GiB 或 5%，请打开数据与存储查看。")
            } else {
                delivery.clear(key: key)
            }
        }
    }

    func presentCoreAlerts(_ alerts: [CorePersistentAlert], enabled: Bool) {
        let codes = Set(alerts.filter(\.active).map(\.code))
        for recovered in lastActiveCodes.subtracting(codes) {
            delivery.clear(key: Self.deliveryKey(recovered))
        }
        lastActiveCodes = codes
        guard enabled else { return }
        for alert in alerts where alert.active && !alert.acknowledged {
            guard alert.code.count <= 80, alert.message.utf8.count <= 512,
                  ["storage_offline", "storage_low_space", "backup_failed",
                   "gallery_scan_failed", "cinema_scan_failed"].contains(alert.code) else { continue }
            // Direct IPC notifications share an identity with persisted alerts.
            if alert.code == "storage_low_space" { continue }
            delivery.deliver(key: Self.deliveryKey(alert.code),
                title: alert.severity == "critical" ? "轻屿 NAS 重要告警" : "轻屿 NAS 运行提醒",
                description: alert.message)
        }
    }

    private static func deliveryKey(_ code: String) -> String {
        if code == "storage_offline" { return "volume-unavailable" }
        if code == "backup_failed" { return "backup-failure" }
        return "journal:" + code
    }
}
