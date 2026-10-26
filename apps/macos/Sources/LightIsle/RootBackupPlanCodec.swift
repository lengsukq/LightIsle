import Foundation

enum NativeRootBackupPlanAction {
    case status
    case configure(path: String, everyHours: Int, retentionCount: Int)
    case disable

    var verb: String {
        switch self {
        case .status: "backup-plan-status"
        case .configure: "backup-plan-set"
        case .disable: "backup-plan-off"
        }
    }
}

enum NativeRootBackupPlanCodec {
    static func command(
        action: NativeRootBackupPlanAction,
        requestID: String,
        rootID: String,
        generation: UInt64
    ) -> String? {
        guard !requestID.isEmpty, requestID.utf8.count <= 64,
              !rootID.isEmpty, generation > 0 else { return nil }

        var request: [String: Any] = [
            "requestID": requestID,
            "rootID": rootID,
            "generation": generation,
        ]
        switch action {
        case .status, .disable:
            break
        case let .configure(path, everyHours, retentionCount):
            guard path.hasPrefix("/"), everyHours == 24 || everyHours == 168,
                  (0...30).contains(retentionCount) else { return nil }
            request["path"] = path
            request["everyHours"] = everyHours
            request["retentionCount"] = retentionCount
        }

        guard let data = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]),
              data.count <= 6000 else { return nil }
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "roots \(action.verb) \(encoded)"
    }
}

struct NativeRootBackupPlan: Decodable, Equatable {
    let rootID: String
    let rootGeneration: UInt64
    let enabled: Bool
    let everyHours: Int
    let destination: String?
    let destinationIdentityStatus: String?
    let retentionCount: Int
    let lastAttempt: Int64
    let nextRun: Int64
    let lastError: String?
    let lastErrorDetail: String?
}

struct NativeRootBackupPlanResult: Decodable, Equatable {
    let rootID: String
    let generation: UInt64
    let schedule: NativeRootBackupPlan
}

enum NativeRootBackupPlanPresentation {
    static func failureDescription(_ code: String, detail: String? = nil) -> String? {
        switch code {
        case "root_backup_plan_config_invalid":
            return "此共享目录的计划配置损坏；其他目录计划不受影响。重新选择周期和独立目的地并保存即可重设，旧配置会先归档保留。"
        case "root_backup_plan_config_unsafe":
            return "此共享目录的计划文件无法安全移动或覆盖，已保持停用；其他目录计划不受影响。请先检查本机计划存储，再重新设置。"
        case "root_backup_plan_archive_failed":
            return "旧版本的目录计划无法安全归档；当前计划与其他目录保持隔离。请检查本机计划存储后再重设。"
        default:
            guard let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else {
                return nil
            }
            return detail
        }
    }
}
