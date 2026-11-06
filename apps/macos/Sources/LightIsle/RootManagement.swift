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
    let isDefault: Bool?
    let maintenance: NativeRootMaintenance?
    var id: String { rootID }
}

struct NativeMigrationPreview: Decodable {
    let sourceRootID: String
    let sourceGeneration: UInt64
    let targetRootID: String
    let targetGeneration: UInt64
    let filesToCopy: Int
    let bytesToCopy: Int64
    let directoriesToMake: Int
    let conflicts: Int
    let protectedFolders: Int
    let unsupportedEntries: Int
    let targetFreeBytes: Int64
    let hasEnoughSpace: Bool
}

struct NativeMigrationStatus: Decodable {
    let phase: String
    let preview: NativeMigrationPreview
    let copiedFiles: Int
    let copiedBytes: Int64
    let skippedFiles: Int
    let startedAt: Int64
    let finishedAt: Int64?
    let error: String?
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

// The owner's native controller is the only place allowed to register
// physical directories or request a verified, copy-only old-data migration.
@MainActor
final class NativeRootsModel: ObservableObject {
    let enabled: Bool
    @Published private(set) var connected = false
    @Published private(set) var roots: [NativeSharedRoot] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published var selectedID = ""
    @Published var migrationSourceID = ""
    @Published var migrationTargetID = ""
    @Published private(set) var migrationPreview: NativeMigrationPreview?
    @Published private(set) var migrationStatus: NativeMigrationStatus?
    /// The containing Mac app owns the FSEvents watcher for the selected
    /// RootRegistry default, not for the retired shared-root path.
    var onDefaultChanged: ((NativeSharedRoot?) -> Void)?
    var onRootsChanged: (([NativeSharedRoot]) -> Void)?

    private var sender: ((String) throws -> Void)?
    private var pendingID: String?
    private var pendingOperation: String?
    private var deadline: Task<Void, Never>?
    private var migrationPolling: Task<Void, Never>?

    var selected: NativeSharedRoot? { roots.first { $0.rootID == selectedID } }
    var additionalRoots: [NativeSharedRoot] { roots }
    var defaultRoot: NativeSharedRoot? { roots.first { $0.isDefault == true } }

    init(enabled: Bool) { self.enabled = enabled }

    func connect(send: @escaping (String) throws -> Void) {
        guard enabled else { return }
        sender = send
        connected = true
        refresh()
    }

    func disconnect() {
        migrationPolling?.cancel()
        migrationPolling = nil
        deadline?.cancel()
        deadline = nil
        pendingID = nil
        pendingOperation = nil
        sender = nil
        connected = false
        busy = false
        roots = []
        onRootsChanged?([])
        migrationPreview = nil
        migrationStatus = nil
        onDefaultChanged?(nil)
    }

    func refresh() { send("list") }
    func selectionChanged() { message = nil }

    func migrationSelectionChanged() {
        migrationPreview = nil
        if migrationStatus?.phase != "running" && migrationStatus?.phase != "previewing" {
            migrationStatus = nil
        }
        message = nil
    }

    func selectFolderAndSwitch() {
        guard connected && !busy else { return }
        let panel = folderPanel("选择默认 NAS 存储文件夹", "切换到此目录")
        panel.message = "已登记的目录直接切换；新目录先安全登记。切换不会移动旧数据或继承另一块盘的权限。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let canonical = url.resolvingSymlinksInPath()
        let components = canonical.pathComponents
        if canonical.path == "/" || canonical.path == "/Volumes" ||
            (components.count == 3 && components[1] == "Volumes") {
            message = "请选择硬盘内专用文件夹，不能直接使用整块硬盘的根目录。"
            return
        }
        let alert = NSAlert()
        alert.messageText = "单独切换默认存储目录？"
        alert.informativeText = "目标：\(canonical.path)\n\n仅修改默认 rootID。旧磁盘和文件保持不变，也不会复制旧成员授权。你可以稍后使用「旧数据迁移」单独复制。"
        alert.addButton(withTitle: "确认切换")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        send("select-folder", path: canonical.path, name: canonical.lastPathComponent)
    }

    private var migrationSelection: [String: Any]? {
        guard let source = roots.first(where: { $0.rootID == migrationSourceID && $0.online }),
              let target = roots.first(where: { $0.rootID == migrationTargetID && $0.online }),
              source.rootID != target.rootID else { return nil }
        return [
            "sourceRootID": source.rootID, "sourceGeneration": source.generation,
            "targetRootID": target.rootID, "targetGeneration": target.generation,
        ]
    }

    func previewMigration() {
        guard connected && !busy, migrationStatus?.phase != "running",
              migrationStatus?.phase != "previewing",
              let selection = migrationSelection else {
            message = "请选择两个不同且在线的已登记存储目录。"
            return
        }
        migrationPreview = nil
        send("migration-preview", fields: selection)
    }

    func startMigration() {
        guard connected && !busy, migrationStatus?.phase != "running",
              migrationStatus?.phase != "previewing",
              let selection = migrationSelection, let preview = migrationPreview,
              preview.sourceRootID == migrationSourceID && preview.targetRootID == migrationTargetID,
              preview.sourceGeneration == selection["sourceGeneration"] as? UInt64,
              preview.targetGeneration == selection["targetGeneration"] as? UInt64,
              preview.hasEnoughSpace else {
            message = "请重新预览当前的来源和目标目录。"
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "开始复制旧存储数据？"
        alert.informativeText = """
        待复制 \(preview.filesToCopy) 个文件，约 \(ByteCountFormatter.string(fromByteCount: preview.bytesToCopy, countStyle: .file))。
        目标已有 \(preview.conflicts) 项冲突，会跳过而非覆盖。

        源文件不会删除；不会自动切换默认盘。
        Users 私人目录及内部数据库、收藏等元数据暂不自动迁移，以免破坏账户授权与硬配额。
        """
        alert.addButton(withTitle: "开始复制")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        send("migration-start", fields: selection)
    }

    func cancelMigration() {
        guard connected && !busy,
              migrationStatus?.phase == "running" || migrationStatus?.phase == "previewing" else { return }
        send("migration-cancel")
    }

    private func scheduleMigrationPoll() {
        migrationPolling?.cancel()
        guard connected,
              migrationStatus?.phase == "running" || migrationStatus?.phase == "previewing" else { return }
        migrationPolling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.connected else { return }
            if self.busy {
                self.scheduleMigrationPoll()
            } else {
                self.send("migration-status")
            }
        }
    }

    func addFolder(onVolume volume: HostVolume? = nil) {
        guard connected && !busy else { return }
        let panel = folderPanel("选择一个共享目录", "添加目录")
        if let volume {
            panel.directoryURL = URL(fileURLWithPath: volume.mount, isDirectory: true)
            panel.message = "请选择“\(volume.name)”磁盘中的专用文件夹，不能使用整块磁盘根目录。"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Owner-selected shares must be dedicated folders, not a mounted
        // external volume's root or the top-level /Volumes directory.
        let selectedURL = url.resolvingSymlinksInPath()
        let components = selectedURL.pathComponents
        if selectedURL.path == "/Volumes" ||
            (components.count == 3 && components[1] == "Volumes") {
            message = "请选择外置硬盘内的专用文件夹，不能直接共享整块磁盘。"
            return
        }
        if let volume {
            let base = URL(fileURLWithPath: volume.mount).resolvingSymlinksInPath().path
            let candidate = url.resolvingSymlinksInPath().path
            guard candidate.hasPrefix(base + "/") else {
                message = "请在选定磁盘内选择专用文件夹，而不是整块磁盘或其他存储位置。"
                return
            }
        }
        send("add", path: url.path, name: url.lastPathComponent)
    }

    func makeSelectedDefault() {
        guard connected && !busy, let selected, selected.online else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "设为默认 NAS 存储空间？"
        alert.informativeText = "将“\(selected.name)”设为默认目录。不会移动文件、合并媒体库或复制成员授权；原硬盘与其他已登记目录保持不变。"
        alert.addButton(withTitle: "设为默认")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        send("set-default", root: selected)
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
        onRootsChanged?(entries)
        onDefaultChanged?(defaultRoot)
        if !additionalRoots.contains(where: { $0.rootID == selectedID }) {
            selectedID = additionalRoots.first?.rootID ?? ""
        }
        if !roots.contains(where: { $0.rootID == migrationTargetID }) {
            migrationTargetID = defaultRoot?.rootID ?? ""
        }
        if !roots.contains(where: { $0.rootID == migrationSourceID }) ||
            migrationSourceID == migrationTargetID {
            migrationSourceID = roots.first(where: { $0.rootID != migrationTargetID })?.rootID ?? ""
        }
        if let preview = migrationPreview,
           !roots.contains(where: {
               $0.rootID == preview.sourceRootID && $0.generation == preview.sourceGeneration
           }) || !roots.contains(where: {
               $0.rootID == preview.targetRootID && $0.generation == preview.targetGeneration
           }) {
            migrationPreview = nil
        }
        // On launch/reconnect recover the last owner-private migration
        // journal before showing an empty task center. A running job from a
        // previous Core is marked interrupted rather than silently lost.
        if migrationStatus == nil { send("migration-status") }
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
              ["add", "remove", "rebind", "set-default", "select-folder",
               "migration-preview", "migration-start", "migration-status", "migration-cancel"].contains(header.operation) else { return }
        finish()
        if let error = header.error {
            message = errorMessage(error)
            return
        }
        if header.operation == "migration-preview" ||
           header.operation == "migration-start" || header.operation == "migration-status" {
            guard let status = try? JSONDecoder().decode(RootReply<NativeMigrationStatus>.self, from: payload).result else {
                message = "无法读取迁移状态，请刷新重试。"
                return
            }
            migrationStatus = status
            switch status.phase {
            case "previewed":
                migrationPreview = status.preview
                message = "迁移预览已完成；没有修改任何原文件。"
            case "completed":
                message = "已复制 \(status.copiedFiles) 个文件。源盘文件仍保留，可在目标目录检查。"
            case "failed":
                message = "预览或复制中断（\(status.error ?? "未知错误")）。源文件未删除，可重新预览后重试。"
            case "cancelled":
                message = "任务已取消，已完成的文件保留，源盘文件未删除。"
            case "interrupted":
                message = "上次迁移因 Core 重启中断。已复制文件仍保留；请重新预览并开始复制，系统会安全跳过已有目标文件。"
            default: break
            }
            scheduleMigrationPoll()
            return
        }
        if header.operation == "migration-cancel" {
            message = "已请求取消，正在停止扫描或复制。"
            scheduleMigrationPoll()
            return
        }
        message = header.operation == "remove"
            ? "已移除登记，原硬盘数据未删除。"
            : (header.operation == "set-default" || header.operation == "select-folder")
            ? "默认 NAS 存储空间已更新。原数据和其他目录均未移动。"
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

    private func send(_ operation: String, root: NativeSharedRoot? = nil, path: String? = nil,
                      name: String? = nil, fields: [String: Any] = [:]) {
        guard connected && !busy, let sender,
              ["list", "add", "rebind", "remove", "set-default", "select-folder",
               "migration-preview", "migration-start", "migration-status", "migration-cancel"].contains(operation) else { return }
        let id = UUID().uuidString.lowercased()
        var arguments: [String: Any] = ["requestID": id]
        if let root { arguments["rootID"] = root.rootID; arguments["generation"] = root.generation }
        if let path { arguments["path"] = path }
        if let name { arguments["name"] = name }
        for (key, value) in fields { arguments[key] = value }
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
        case "migration_invalid_roots", "root_registry_invalid": return "来源和目标目录无效，请重新选择。"
        case "migration_already_running": return "已有旧数据迁移任务进行中，请先结束当前任务。"
        case "migration_scan_limit": return "旧目录文件量超过安全扫描上限，请先分批整理旧目录。"
        case "migration_source_changed": return "旧目录中的文件在迁移时发生变化，已停止复制，请检查后重试。"
        case "migration_insufficient_space": return "目标硬盘剩余空间不足，无法安全复制。请释放空间或另选目标目录。"
        default: return "目录操作失败（\(code)）。请检查连接并刷新状态。"
        }
    }
}
