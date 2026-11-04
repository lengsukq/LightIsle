import Foundation

/// Parse typed status reports from the native Core pipe without touching
/// SwiftUI state. An invalid payload still consumes its protocol line.
enum CoreIPCReportEvent {
    case alerts([CorePersistentAlert]?)
    case backupInventory(NASBackupInventory?)
    case disks([ManagedDisk]?)
    case diskHealth(DiskHealthReport?)
    case storageThreshold(StorageThreshold?)
    case tunnel(TunnelState?)
    case notify(NotifyStats?)
    case backupStatus(NASBackupStatus?)
    case backupSchedule(NASBackupSchedule?)
    case hostMetrics(HostMetrics?)

    static func decode(_ line: String) -> Self? {
        func payload<T: Decodable>(_ type: T.Type, prefix: String) -> T? {
            let raw = String(line.dropFirst(prefix.count))
            return CoreIPCPayloadCodec.decodeJSON(type, raw: raw)
        }
        if line.hasPrefix("LIGHTISLE_ALERTS ") {
            let raw = String(line.dropFirst("LIGHTISLE_ALERTS ".count))
            return .alerts(raw.count <= 64_000
                ? CoreIPCPayloadCodec.decodeJSON([CorePersistentAlert].self, raw: raw)
                : nil)
        }
        if line.hasPrefix("LIGHTISLE_BACKUP_INVENTORY ") {
            return .backupInventory(payload(NASBackupInventory.self, prefix: "LIGHTISLE_BACKUP_INVENTORY "))
        }
        if line.hasPrefix("LIGHTISLE_DISKS ") {
            return .disks(payload([ManagedDisk].self, prefix: "LIGHTISLE_DISKS "))
        }
        if line.hasPrefix("LIGHTISLE_DISK_SMART ") {
            return .diskHealth(payload(DiskHealthReport.self, prefix: "LIGHTISLE_DISK_SMART "))
        }
        if line.hasPrefix("LIGHTISLE_ALERTS_THRESHOLD ") {
            return .storageThreshold(payload(StorageThreshold.self, prefix: "LIGHTISLE_ALERTS_THRESHOLD "))
        }
        if line.hasPrefix("LIGHTISLE_TUNNEL_STATUS ") {
            return .tunnel(payload(TunnelState.self, prefix: "LIGHTISLE_TUNNEL_STATUS "))
        }
        if line.hasPrefix("LIGHTISLE_TUNNEL_STATE ") {
            return .tunnel(payload(TunnelState.self, prefix: "LIGHTISLE_TUNNEL_STATE "))
        }
        if line.hasPrefix("LIGHTISLE_NOTIFY_STATUS ") {
            return .notify(payload(NotifyStats.self, prefix: "LIGHTISLE_NOTIFY_STATUS "))
        }
        if line.hasPrefix("LIGHTISLE_BACKUP_STATUS ") {
            return .backupStatus(payload(NASBackupStatus.self, prefix: "LIGHTISLE_BACKUP_STATUS "))
        }
        if line.hasPrefix("LIGHTISLE_BACKUP_SCHEDULE ") {
            return .backupSchedule(payload(NASBackupSchedule.self, prefix: "LIGHTISLE_BACKUP_SCHEDULE "))
        }
        if line.hasPrefix("LIGHTISLE_STATS ") {
            return .hostMetrics(payload(HostMetrics.self, prefix: "LIGHTISLE_STATS "))
        }
        return nil
    }
}
