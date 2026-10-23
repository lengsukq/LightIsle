import Foundation

struct NASMetadataCountDifference: Decodable {
    let current: Int64?
    let staged: Int64?
    let delta: Int64?
}

struct NASMetadataPreviewError: Decodable {
    let code: String
    let message: String
}

struct NASMetadataRecoveryPreview: Decodable {
    let schemaVersion: Int
    let operation: String
    let status: String
    let verified: Bool
    let manifestSHA256: String
    let counts: [String: NASMetadataCountDifference]
    let warnings: [String]
    let error: NASMetadataPreviewError?

    var isReady: Bool {
        schemaVersion == 1 && operation == "preview" && status == "ready" &&
            verified && manifestSHA256.count == 64
    }
}

func backupFailureDescription(_ code: String) -> String {
    let known: [(String, String)] = [
        ("backup_destination_confirmation_required", "旧计划尚未绑定磁盘身份。请重新选择每天或每周，并确认备份目录。"),
        ("backup_destination_volume_unavailable", "备份磁盘不可用或无法确认身份，请连接原磁盘后重试。"),
        ("backup_destination_volume_mismatch", "此路径上的磁盘已变化，未向新磁盘写入。请重新选择目录确认。"),
        ("backup_destination_folder_changed", "备份文件夹已被替换，未派发任务。请重新选择目录确认。"),
        ("backup_schedule_save_failed", "无法保存备份计划，本次未派发新的计划任务。"),
        ("backup_retention_identity_unavailable", "无法确认共享磁盘的稳定身份，已保留全部旧快照。"),
        ("backup_retention_scan_limit", "旧快照超过安全检查上限，未执行自动清理。"),
        ("backup_retention_snapshot_untrusted", "旧快照存在无法验证的内容，已停止清理，请检查备份目录。"),
        ("backup_retention_snapshot_changed", "清理时发现旧快照发生变化，已停止继续清理。"),
        ("backup_source_identity_changed", "备份过程中共享目录发生变化，本次备份已停止。"),
        ("context canceled", "操作已取消；已完成的新快照仍会保留。")
    ]
    return known.first(where: { code.contains($0.0) })?.1 ?? code
}
