import Foundation

@main
struct RootManagementRegression {
    @MainActor
    static func main() throws {
        let disabled = NativeRootsModel(enabled: false)
        disabled.connect { _ in fatalError("disabled preview sent a command") }
        precondition(!disabled.connected)

        let model = NativeRootsModel(enabled: true)
        var commands: [String] = []
        model.connect { commands.append($0) }
        precondition(model.busy && commands.count == 1)

        func requestID(_ command: String) throws -> String {
            let word = command.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").last!
            var encoded = String(word).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            let object = try JSONSerialization.jsonObject(with: Data(base64Encoded: encoded)!) as! [String: Any]
            return object["requestID"] as! String
        }
        func reply(_ id: String, operation: String, result: Any? = nil, error: String? = nil) throws -> String {
            var object: [String: Any] = ["schemaVersion": 1, "operation": operation, "requestID": id]
            if let result { object["result"] = result }
            if let error { object["error"] = error }
            return try JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        func root(_ id: String, generation: Int = 1, compatibility: Bool = false) -> [String: Any] {
            ["rootID": id, "generation": generation, "name": "fixture", "path": "/fixture/" + id,
             "online": true, "pending": false, "compatibility": compatibility]
        }
        let firstRequest = try requestID(commands[0])
        model.consume(try reply("unrelated-old-request", operation: "list", result: [root("wrong")]))
        precondition(model.busy && model.roots.isEmpty, "late reply changed current state")
        model.consume(try reply(firstRequest, operation: "list", result: [root("legacy", compatibility: true), root("a"), root("b")]))
        precondition(!model.busy && model.additionalRoots.count == 2 && model.selectedID == "a")
        model.selectionChanged()
        let statusRequest = try requestID(commands.last!)
        model.consume(try reply(firstRequest, operation: "list", error: "root_registry_offline"))
        precondition(model.busy && model.message == nil, "stale error cleared a newer request")
        let status: [String: Any] = ["running": false, "operation": "backup", "files": 2, "bytes": 8]
        model.consume(try reply(statusRequest, operation: "backup-status", result: ["rootID": "a", "generation": 1, "status": status]))
        precondition(!model.busy && model.backupStatus?.files == 2)

        model.selectedID = "b"
        model.selectionChanged()
        let bRequest = try requestID(commands.last!)
        model.consume(try reply(statusRequest, operation: "backup-status", result: ["rootID": "a", "generation": 1, "status": status]))
        precondition(model.busy && model.backupStatus == nil, "old root result became the new root status")
        model.consume(try reply(bRequest, operation: "backup-status", result: ["rootID": "b", "generation": 1, "status": status]))
        precondition(model.backupStatus?.files == 2)

        model.refresh()
        let generationRefresh = try requestID(commands.last!)
        model.consume(try reply(generationRefresh, operation: "list", result: [root("a"), root("b", generation: 2)]))
        precondition(model.selectedID == "b" && model.selected?.generation == 2 && model.backupStatus == nil,
                     "rebound root retained old-generation backup state")
        let refreshedStatus = try requestID(commands.last!)
        precondition(refreshedStatus != generationRefresh && model.busy, "generation change did not refresh status")
        model.consume(try reply(refreshedStatus, operation: "backup-status", result: ["rootID": "b", "generation": 2, "status": status]))

        model.refresh()
        let interruptedRequest = try requestID(commands.last!)
        model.disconnect()
        precondition(!model.connected && !model.busy && model.backupStatus == nil)
        model.connect { commands.append($0) }
        let newRequest = try requestID(commands.last!)
        model.consume(try reply(interruptedRequest, operation: "list", result: [root("stale")]))
        precondition(model.busy && model.selectedID == "b", "prior Core response crossed a restart")
        model.consume(try reply(newRequest, operation: "list", result: [root("a", generation: 2)]))
        precondition(!model.busy && model.selected?.generation == 2 && model.selectedID == "a")
        model.disconnect()
        print("PASS: native root selection, stale responses, restart isolation, preview disabled")
    }
}
