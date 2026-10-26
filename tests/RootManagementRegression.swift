import Foundation

@main
struct RootManagementRegression {
    @MainActor
    static func main() throws {
        let disabled = NativeRootsModel(enabled: false)
        disabled.connect { _ in fatalError("disabled root preview sent IPC") }
        precondition(!disabled.connected)

        let model = NativeRootsModel(enabled: true)
        var commands: [String] = []
        model.connect { commands.append($0) }
        precondition(model.busy && commands.count == 1)

        func command(_ index: Int) throws -> (String, [String: Any]) {
            let parts = commands[index].trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            guard parts.count == 3, parts[0] == "roots",
                  let bytes = Data(base64URL: String(parts[2])),
                  let payload = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw RegressionError.badCommand
            }
            return (String(parts[1]), payload)
        }
        func response(_ operation: String, _ payload: [String: Any], _ result: Any? = nil, _ error: String? = nil) throws -> String {
            var message: [String: Any] = [
                "schemaVersion": 1, "operation": operation,
                "requestID": payload["requestID"] ?? "",
            ]
            if let result { message["result"] = result }
            if let error { message["error"] = error }
            return try JSONSerialization.data(withJSONObject: message).base64URLString
        }
        func root(_ id: String, _ generation: Int = 1, _ online: Bool = true) -> [String: Any] {
            ["rootID": id, "generation": generation, "name": id, "path": "/fixture/" + id,
             "online": online, "pending": false, "compatibility": false]
        }
        let first = try command(0)
        precondition(first.0 == "list")
        model.consume(try response("list", ["requestID": "wrong"], [root("stale")]))
        precondition(model.busy && model.roots.isEmpty)
        model.consume(try response("list", first.1, [root("a"), root("b", 2, false)]))
        precondition(!model.busy && model.additionalRoots.count == 2 && model.selectedID == "a")
        precondition(commands.count == 1, "root listing started hidden backup polling")
        model.selectedID = "b"
        model.selectionChanged()
        precondition(!model.busy && model.selected?.online == false)
        model.refresh()
        let second = try command(1)
        precondition(second.0 == "list")
        model.disconnect()
        precondition(!model.connected && !model.busy)
        model.connect { commands.append($0) }
        let third = try command(2)
        model.consume(try response("list", second.1, [root("stale")]))
        precondition(model.busy && model.roots.isEmpty)
        model.consume(try response("list", third.1, [root("a", 2)]))
        precondition(!model.busy && model.selectedID == "a" && model.selected?.generation == 2)
        precondition(commands.allSatisfy { $0.contains("roots list ") }, "discontinued disk backup IPC was sent")
        model.disconnect()
        print("PASS: home NAS root management, role-safe disk selection, stale IPC and no root backup polling")
    }
}

private enum RegressionError: Error { case badCommand }
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
