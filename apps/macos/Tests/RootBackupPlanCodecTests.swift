import Foundation

@main
enum RootBackupPlanCodecTests {
    static func main() throws {
        let rootID = "root-123"
        let status = try payload(.status, rootID: rootID)
        precondition(Set(status.keys) == Set(["requestID", "rootID", "generation"]))

        let disabled = try payload(.disable, rootID: rootID)
        precondition(Set(disabled.keys) == Set(["requestID", "rootID", "generation"]))

        let configure = try payload(.configure(path: "/Volumes/Backup/LightIsle", everyHours: 168, retentionCount: 0), rootID: rootID)
        precondition(Set(configure.keys) == Set(["requestID", "rootID", "generation", "path", "everyHours", "retentionCount"]))
        precondition(configure["everyHours"] as? Int == 168)
        precondition(configure["retentionCount"] as? Int == 0)
        precondition(NativeRootBackupPlanCodec.command(
            action: .configure(path: "relative/path", everyHours: 24, retentionCount: 0),
            requestID: "request-1", rootID: rootID, generation: 7
        ) == nil)
        precondition(NativeRootBackupPlanCodec.command(
            action: .configure(path: "/Volumes/Backup", everyHours: 24, retentionCount: 31),
            requestID: "request-1", rootID: rootID, generation: 7
        ) == nil)

        let encodedReply = Data(#"{"rootID":"root-123","generation":7,"schedule":{"rootID":"root-123","rootGeneration":7,"enabled":false,"everyHours":0,"destination":"/Volumes/Backup","destinationIdentityStatus":"bound","retentionCount":0,"lastAttempt":42,"nextRun":0,"lastError":"root_backup_plan_config_invalid","lastErrorDetail":"The saved plan is invalid.","ignoredExtra":true}}"#.utf8)
        let reply = try JSONDecoder().decode(NativeRootBackupPlanResult.self, from: encodedReply)
        precondition(reply.rootID == rootID && reply.generation == 7)
        precondition(!reply.schedule.enabled && reply.schedule.retentionCount == 0)
        precondition(reply.schedule.destination == "/Volumes/Backup")
        precondition(reply.schedule.lastAttempt == 42 && reply.schedule.nextRun == 0)
        precondition(reply.schedule.lastError == "root_backup_plan_config_invalid")
        precondition(reply.schedule.lastErrorDetail == "The saved plan is invalid.")
        precondition(NativeRootBackupPlanPresentation.failureDescription(reply.schedule.lastError!)?.contains("其他目录计划不受影响") == true)
        precondition(NativeRootBackupPlanPresentation.failureDescription("root_backup_plan_config_unsafe")?.contains("无法安全移动或覆盖") == true)
        precondition(NativeRootBackupPlanPresentation.failureDescription("root_backup_plan_archive_failed")?.contains("无法安全归档") == true)
        precondition(NativeRootBackupPlanPresentation.failureDescription("future_error", detail: "Safe recovery hint") == "Safe recovery hint")
    }

    private static func payload(_ action: NativeRootBackupPlanAction, rootID: String) throws -> [String: Any] {
        guard let command = NativeRootBackupPlanCodec.command(
            action: action, requestID: "request-1", rootID: rootID, generation: 7
        ) else { throw Failure.invalidCommand }
        let encoded = String(command.split(separator: " ").last!)
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidPayload
        }
        return object
    }

    private enum Failure: Error {
        case invalidCommand
        case invalidPayload
    }
}
