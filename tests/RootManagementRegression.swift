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
        var defaultChanges: [String?] = []
        model.onDefaultChanged = { defaultChanges.append($0?.rootID) }
        model.connect { commands.append($0) }
        precondition(model.busy && commands.count == 1)

        func command(_ index: Int) throws -> (String, [String: Any]) {
            let parts = commands[index].trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            guard parts.count == 3, parts[0] == "roots",
                  let bytes = Data(base64URLEncoded: String(parts[2])),
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
            return try JSONSerialization.data(withJSONObject: message).base64URLEncodedString
        }
        func root(_ id: String, _ generation: Int = 1, _ online: Bool = true, isDefault: Bool = false) -> [String: Any] {
            ["rootID": id, "generation": generation, "name": id, "path": "/fixture/" + id,
             "online": online, "pending": false, "isDefault": isDefault]
        }

        let first = try command(0)
        precondition(first.0 == "list")
        model.consume(try response("list", ["requestID": "wrong"], [root("stale")]))
        precondition(model.busy && model.roots.isEmpty)

        model.consume(try response("list", first.1, [root("a", 1, true, isDefault: true), root("b", 2, false)]))
        precondition(!model.busy && model.additionalRoots.count == 2 && model.selectedID == "a")
        precondition(model.defaultRoot?.rootID == "a" && defaultChanges == ["a"])
        precondition(commands.count == 1, "unexpected background migration or backup polling IPC")

        model.selectedID = "b"
        model.selectionChanged()
        precondition(!model.busy && model.selected?.online == false)

        model.refresh()
        let second = try command(1)
        precondition(second.0 == "list")

        model.disconnect()
        precondition(!model.connected && !model.busy && model.roots.isEmpty)
        precondition(defaultChanges.last == .some(nil))

        model.connect { commands.append($0) }
        let third = try command(2)
        precondition(third.0 == "list")
        model.consume(try response("list", second.1, [root("stale")]))
        precondition(model.busy && model.roots.isEmpty)

        model.consume(try response("list", third.1, [root("a", 2, true, isDefault: true)]))
        precondition(!model.busy && model.selectedID == "a" && model.selected?.generation == 2)
        precondition(commands.count == 3 && commands.allSatisfy {
            $0.hasPrefix("roots list ")
        }, "discontinued migration or disk backup polling IPC was sent")

        // Verify upfront real read/write probing and daemon verify-access IPC.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightisle-perm-regression-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer {
            _ = chmod(tempRoot.path, 0o700)
            try? FileManager.default.removeItem(at: tempRoot)
        }
        let okProbe = StoragePermissionHelper.probeDirectoryReadWrite(at: tempRoot)
        precondition(okProbe.isWritable, "expected writable probe on temp directory")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempRoot.path)
        precondition(leftovers.isEmpty, "expected probe file cleanup, got \(leftovers)")

        precondition(chmod(tempRoot.path, 0o500) == 0)
        let deniedProbe = StoragePermissionHelper.probeDirectoryReadWrite(at: tempRoot)
        precondition(!deniedProbe.isWritable, "expected non-writable probe on 0500 directory")
        precondition(chmod(tempRoot.path, 0o700) == 0)

        var verifyResult: Bool?
        model.verifyAccess(path: tempRoot.path, autoRepairOnDenied: false) { ok, _ in
            verifyResult = ok
        }
        let fourth = try command(3)
        precondition(fourth.0 == "verify-access")
        model.consume(try response("verify-access", fourth.1, ["verified": true]))
        precondition(!model.busy && verifyResult == true)

        model.disconnect()
        print("PASS: home NAS root management, upfront permission probing, stale IPC and zero migration/backup polling")
    }
}

private enum RegressionError: Error { case badCommand }
