import AppKit
import Foundation
import SwiftUI

struct NativeSharedRoot: Decodable, Identifiable {
    let rootID: String
    let generation: UInt64
    let name: String
    let path: String
    let online: Bool
    let pending: Bool
    let maintenance: NativeRootMaintenance?
    var id: String { rootID }
}

struct NativeRootMaintenance: Decodable {
    let rootID: String
    let generation: UInt64
    let status: String
    let lastAttempt: Int64
    let lastSuccess: Int64
}

private struct RootReply<Value: Decodable>: Decodable {
    let schemaVersion: Int
    let operation: String
    let requestID: String?
    let error: String?
    let result: Value?
}

// Home edition: this model only registers, reconnects and forgets physical
// directories. Legacy migration and whole-disk snapshot jobs are removed.
@MainActor
final class NativeRootsModel: ObservableObject {
    let enabled: Bool
    @Published private(set) var connected = false
    @Published private(set) var roots: [NativeSharedRoot] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published var selectedID = ""

    private var sender: ((String) throws -> Void)?
    private var pendingID: String?
    private var pendingOperation: String?
    private var deadline: Task<Void, Never>?

    var selected: NativeSharedRoot? { roots.first { $0.rootID == selectedID } }
    var additionalRoots: [NativeSharedRoot] { roots }

    init(enabled: Bool) { self.enabled = enabled }

    func connect(send: @escaping (String) throws -> Void) {
        guard enabled else { return }
        sender = send
        connected = true
        refresh()
    }

    func disconnect() {
        deadline?.cancel()
        deadline = nil
        pendingID = nil
        pendingOperation = nil
        sender = nil
        connected = false
        busy = false
        roots = []
    }

    func refresh() { send("list") }
    func selectionChanged() { message = nil }

    func addFolder() {
        guard connected && !busy else { return }
        let panel = folderPanel("选择一个共享目录", "添加目录")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        send("add", path: url.path, name: url.lastPathComponent)
    }

    func reconnectSelected() {
        guard connected && !busy, let selected else { return }
        let panel = folderPanel("重新连接原硬盘上的目录", "确认目录")
        panel.directoryURL = URL(fileURLWithPath: selected.path).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "重新连接原来的物理目录？"
        alert.informativeText = "只允许原来的磁盘与目录。如果已换硬盘，请先移除旧登记，再添加新目录并重新分配成员空间。文件不会自动迁移。"
        alert.addButton(withTitle: "确认连接")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        send("rebind", root: selected, path: url.path)
    }

    func removeSelected() {
        guard connected && !busy, let selected else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "移除“\(selected.name)”的共享登记？"
        alert.informativeText = "只移除 LightIsle 登记，不删除原盘文件。若有用户空间指向此目录，请到 Web → 成员存储空间解除旧绑定，再选新盘创建空白空间。"
        alert.addButton(withTitle: "移除登记")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        send("remove", root: selected)
    }

    func consume(_ encoded: String) {
        guard enabled && connected && encoded.utf8.count <= 180_000,
              let payload = Self.decode(encoded), let value = try? JSONDecoder().decode(RootReply<[NativeSharedRoot]>.self, from: payload),
              value.schemaVersion == 1,
              value.operation == pendingOperation, value.requestID == pendingID else {
            // For add/remove/rebind, result is a root or acknowledgment rather
            // than a list. Decode the shared header separately.
            consumeMutation(encoded)
            return
        }
        guard value.operation == "list" else { return }
        finish()
        if let error = value.error {
            message = errorMessage(error)
            return
        }
        guard let entries = value.result, entries.count <= 16 else {
            message = "目录列表无法读取，请刷新。"
            return
        }
        roots = entries
        if !additionalRoots.contains(where: { $0.rootID == selectedID }) {
            selectedID = additionalRoots.first?.rootID ?? ""
        }
    }

    private func consumeMutation(_ encoded: String) {
        struct Header: Decodable {
            let schemaVersion: Int
            let operation: String
            let requestID: String?
            let error: String?
        }
        guard let payload = Self.decode(encoded),
              let header = try? JSONDecoder().decode(Header.self, from: payload),
              header.schemaVersion == 1, header.requestID == pendingID,
              header.operation == pendingOperation,
              ["add", "remove", "rebind"].contains(header.operation) else { return }
        finish()
        if let error = header.error {
            message = errorMessage(error)
            return
        }
        message = header.operation == "remove"
            ? "已移除登记，原硬盘数据未删除。"
            : "存储位置已更新。如有成员使用，请在 Web 中确认目录分配。"
        refresh()
    }

    private func finish() {
        deadline?.cancel()
        deadline = nil
        pendingID = nil
        pendingOperation = nil
        busy = false
    }

    private func send(_ operation: String, root: NativeSharedRoot? = nil, path: String? = nil, name: String? = nil) {
        guard connected && !busy, let sender,
              ["list", "add", "rebind", "remove"].contains(operation) else { return }
        let id = UUID().uuidString.lowercased()
        var arguments: [String: Any] = ["requestID": id]
        if let root { arguments["rootID"] = root.rootID; arguments["generation"] = root.generation }
        if let path { arguments["path"] = path }
        if let name { arguments["name"] = name }
        guard let data = try? JSONSerialization.data(withJSONObject: arguments),
              data.count <= 6000 else { return }
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        do {
            pendingID = id
            pendingOperation = operation
            busy = true
            try sender("roots \(operation) \(encoded)\n")
            deadline?.cancel()
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(18))
                guard !Task.isCancelled, let self, self.pendingID == id else { return }
                self.finish()
                self.message = "操作结果尚未确认，请刷新目录状态后再操作。"
            }
        } catch {
            message = "无法连接本机服务，请检查 LightIsle 是否运行。"
            disconnect()
        }
    }

    private func folderPanel(_ title: String, _ prompt: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel
    }

    private static func decode(_ value: String) -> Data? {
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }

    private func errorMessage(_ code: String) -> String {
        switch code {
        case "root_registry_offline": return "硬盘离线，请检查连接、供电与挂载，然后刷新重试。"
        case "root_registry_busy": return "当前目录正在使用，请结束相关任务后重试。"
        case "root_registry_overlap": return "此目录与现有存储空间重叠，请另选文件夹。"
        case "root_registry_stale", "root_registry_unknown": return "存储登记已变化，请刷新后重试。"
        case "root_registry_other_folder_requires_add": return "不能把旧目录绑定到另一块盘。请先移除旧登记再新增。"
        default: return "目录操作失败（\(code)）。请检查连接并刷新状态。"
        }
    }
}
