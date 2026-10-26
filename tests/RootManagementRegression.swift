import Foundation

@main
struct RootManagementRegression {
    @MainActor
    static func main() async throws {
        let disabled = NativeRootsModel(enabled: false)
        disabled.connect { _ in fatalError("disabled preview sent a command") }
        precondition(!disabled.connected)

        let model = NativeRootsModel(enabled: true)
        var commands: [String] = []
        model.connect { commands.append($0) }
        precondition(model.busy && commands.count == 1)

        func decodedRequest(_ command: String) throws -> (operation: String, payload: [String: Any]) {
            let words = command.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            guard words.count == 3, words[0] == "roots",
                  let data = Data(base64URL: String(words[2])),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.invalidRequest
            }
            return (String(words[1]), payload)
        }

        func reply(_ id: String, operation: String, result: Any? = nil, error: String? = nil) throws -> String {
            var object: [String: Any] = ["schemaVersion": 1, "operation": operation, "requestID": id]
            if let result { object["result"] = result }
            if let error { object["error"] = error }
            return try JSONSerialization.data(withJSONObject: object).base64URLString
        }

        func root(_ id: String, generation: Int = 1, compatibility: Bool = false) -> [String: Any] {
            ["rootID": id, "generation": generation, "name": "fixture", "path": "/fixture/" + id,
             "online": true, "pending": false, "compatibility": compatibility]
        }

        func schedule(_ id: String, generation: Int, enabled: Bool, destination: String? = nil) -> [String: Any] {
            var value: [String: Any] = [
                "rootID": id, "rootGeneration": generation, "enabled": enabled,
                "everyHours": enabled ? 24 : 0, "destinationIdentityStatus": enabled ? "bound" : "",
                "retentionCount": 0, "lastAttempt": 0, "nextRun": enabled ? 1_900_000_000 : 0,
            ]
            if let destination { value["destination"] = destination }
            return value
        }

        func planResult(_ id: String, generation: Int, enabled: Bool, destination: String? = nil) -> [String: Any] {
            ["rootID": id, "generation": generation,
             "schedule": schedule(id, generation: generation, enabled: enabled, destination: destination)]
        }

        func backupStatus(_ running: Bool, files: Int = 0, bytes: Int = 0) -> [String: Any] {
            ["running": running, "operation": "backup", "files": files, "bytes": bytes]
        }

        func pendingRequest(_ operation: String, at index: Int? = nil) throws -> (id: String, payload: [String: Any]) {
            let command = commands[index ?? (commands.count - 1)]
            let decoded = try decodedRequest(command)
            precondition(decoded.operation == operation, "expected \(operation), got \(decoded.operation)")
            guard let id = decoded.payload["requestID"] as? String else { throw Failure.invalidRequest }
            return (id, decoded.payload)
        }

        func waitForStatusPoll() async throws {
            try await Task.sleep(for: .seconds(4))
        }

        let first = try pendingRequest("list")
        model.consume(try reply("unrelated-old-request", operation: "list", result: [root("wrong")]))
        precondition(model.busy && model.roots.isEmpty, "late reply changed current state")
        model.consume(try reply(first.id, operation: "list", result: [root("legacy", compatibility: true), root("a"), root("b")]))
        precondition(model.busy && model.additionalRoots.count == 2 && model.selectedID == "a",
                     "root selection did not request the first plan status")

        let firstPlan = try pendingRequest("backup-plan-status")
        precondition(firstPlan.payload["rootID"] as? String == "a" && firstPlan.payload["generation"] as? Int == 1)
        model.consume(try reply(firstPlan.id, operation: "list", error: "root_registry_offline"))
        precondition(model.busy && model.message == nil, "wrong operation consumed the pending plan request")

        model.consume(try reply(firstPlan.id, operation: "backup-plan-status", result: planResult("a", generation: 1, enabled: true, destination: "/Volumes/Backup")))
        precondition(model.busy && commands.count == 3, "plan status must serialize before backup status")
        let initialBackupStatus = try pendingRequest("backup-status")
        precondition(initialBackupStatus.payload["rootID"] as? String == "a" &&
                     initialBackupStatus.payload["generation"] as? Int == 1,
                     "plan status requested backup status for a different root generation")
        model.consume(try reply(initialBackupStatus.id, operation: "backup-status",
                                result: ["rootID": "a", "generation": 1, "status": backupStatus(true, files: 2, bytes: 4096)]))
        precondition(!model.busy && model.backupStatus?.running == true && model.backupStatus?.files == 2 && model.backupStatus?.bytes == 4096,
                     "automatic backup progress was not surfaced")

        model.disableBackupPlan()
        let disable = try pendingRequest("backup-plan-off")
        let beforeBusyPoll = commands.count
        try await waitForStatusPoll()
        precondition(commands.count == beforeBusyPoll && model.busy,
                     "backup status polling overwrote an in-flight disable request instead of queueing")
        model.consume(try reply(disable.id, operation: "backup-plan-off",
                                result: planResult("a", generation: 1, enabled: false, destination: "/Volumes/Backup")))
        precondition(model.message?.contains("已开始的本次备份会继续") == true,
                     "disabling a plan did not explain that it only stops future runs")
        precondition(model.busy, "disabling a plan did not request the active task status")
        let statusAfterDisable = try pendingRequest("backup-status")
        model.consume(try reply(statusAfterDisable.id, operation: "backup-status",
                                result: ["rootID": "a", "generation": 1, "status": backupStatus(true, files: 3, bytes: 8192)]))
        precondition(model.backupPlan?.enabled == false && model.backupStatus?.running == true && model.backupStatus?.files == 3,
                     "disabling future runs cancelled or hid the current backup")

        model.cancelBackup()
        let cancel = try pendingRequest("backup-cancel")
        let beforeBusyCancelPoll = commands.count
        try await waitForStatusPoll()
        precondition(commands.count == beforeBusyCancelPoll && model.busy,
                     "status poll overwrote the in-flight cancel request")
        model.consume(try reply(cancel.id, operation: "backup-cancel",
                                result: ["rootID": "a", "generation": 1, "status": backupStatus(true, files: 4, bytes: 10_240)]))
        precondition(model.busy, "running backup stopped being monitored after the cancel request")
        let continuedPoll = try pendingRequest("backup-status")
        model.consume(try reply(continuedPoll.id, operation: "backup-status",
                                result: ["rootID": "a", "generation": 1, "status": backupStatus(false, files: 5, bytes: 12_288)]))
        precondition(model.backupStatus?.running == false && model.backupStatus?.files == 5,
                     "polling did not observe completion after plan disable")
        let commandCountAfterCompletion = commands.count
        try await waitForStatusPoll()
        precondition(commands.count == commandCountAfterCompletion,
                     "backup status polling continued after the current task completed")

        model.selectedID = "b"
        model.selectionChanged()
        let bPlan = try pendingRequest("backup-plan-status")
        model.consume(try reply(continuedPoll.id, operation: "backup-status",
                                result: ["rootID": "a", "generation": 1, "status": backupStatus(true)]))
        precondition(model.busy && model.backupStatus == nil, "old root status crossed a selection change")
        model.consume(try reply(bPlan.id, operation: "backup-plan-status", result: planResult("a", generation: 1, enabled: true)))
        precondition(!model.busy && model.backupPlan == nil, "plan status for another root was accepted")

        model.selectionChanged()
        let bPlanRetry = try pendingRequest("backup-plan-status")
        model.consume(try reply(bPlanRetry.id, operation: "backup-plan-status", result: planResult("b", generation: 1, enabled: false)))
        let bBackupStatus = try pendingRequest("backup-status")
        model.consume(try reply(bBackupStatus.id, operation: "backup-status",
                                result: ["rootID": "b", "generation": 1, "status": backupStatus(false)]))

        model.refresh()
        let generationRefresh = try pendingRequest("list")
        model.consume(try reply(generationRefresh.id, operation: "list", result: [root("a"), root("b", generation: 2)]))
        precondition(model.selectedID == "b" && model.selected?.generation == 2 && model.backupStatus == nil,
                     "rebound root retained old-generation backup state")
        let refreshedPlan = try pendingRequest("backup-plan-status")
        model.consume(try reply(refreshedPlan.id, operation: "backup-plan-status", result: planResult("b", generation: 1, enabled: true)))
        precondition(!model.busy && model.backupPlan == nil && model.backupStatus == nil,
                     "old-generation plan result crossed a rebind")

        model.selectionChanged()
        let currentPlan = try pendingRequest("backup-plan-status")
        model.consume(try reply(currentPlan.id, operation: "backup-plan-status", result: planResult("b", generation: 2, enabled: false)))
        let currentBackupStatus = try pendingRequest("backup-status")
        model.consume(try reply(currentBackupStatus.id, operation: "backup-status",
                                result: ["rootID": "b", "generation": 2, "status": backupStatus(false)]))

        model.refresh()
        let interrupted = try pendingRequest("list")
        model.disconnect()
        precondition(!model.connected && !model.busy && model.backupStatus == nil)
        model.connect { commands.append($0) }
        let restarted = try pendingRequest("list")
        model.consume(try reply(interrupted.id, operation: "list", result: [root("stale")]))
        precondition(model.busy && model.selectedID == "b", "prior Core response crossed a restart")
        model.consume(try reply(restarted.id, operation: "list", result: [root("a", generation: 2)]))
        precondition(model.busy && model.selected?.generation == 2 && model.selectedID == "a",
                     "list reply did not serialize its plan status refresh")
        let postRestartPlan = try pendingRequest("backup-plan-status")
        model.consume(try reply(postRestartPlan.id, operation: "backup-plan-status", result: planResult("a", generation: 2, enabled: false)))
        let postRestartStatus = try pendingRequest("backup-status")
        model.consume(try reply(postRestartStatus.id, operation: "backup-status",
                                result: ["rootID": "a", "generation": 2, "status": backupStatus(false)]))
        model.disconnect()
        print("PASS: native root selection, serialized plan/task status, running cancellation semantics, root/generation isolation, restart isolation, preview disabled")
    }
}

private enum Failure: Error {
    case invalidRequest
}

private extension Data {
    init?(base64URL: String) {
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }

    var base64URLString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
