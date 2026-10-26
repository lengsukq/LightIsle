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
    let compatibility: Bool
    let maintenance: NativeRootMaintenance?
    var id: String { rootID }
}

struct NativeScopedMediaCounts: Decodable {
    let photos: Int64
    let sharedAlbums: Int64
    let privateAlbums: Int64
    let privateAlbumItems: Int64
    let personalFavorites: Int64
    let films: Int64
    let watchProgress: Int64
    let otherPhotos: Int64
    let otherFilms: Int64
}

struct NativeMigrationCounts: Decodable {
    let members: Int64
    let fileGrants: Int64
    let fileShares: Int64
    let rootGrants: Int64
    let photos: Int64
    let sharedAlbums: Int64
    let privateAlbums: Int64
    let privateAlbumItems: Int64
    let personalFavorites: Int64
    let films: Int64
    let watchProgress: Int64
}

struct NativeLegacyMigrationPreview: Decodable {
    let compatibilityRootID: String?
    let legacyRootFound: Bool
    let physicalRootVerified: Bool
    let pending: Bool
    let counts: NativeMigrationCounts
    let scoped: NativeScopedMediaCounts?
    let blockers: [String]
    let canApply: Bool
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
    let error: String?
    let result: Value?
}

private struct RootReplyHeader: Decodable {
    let schemaVersion: Int
    let operation: String
    let error: String?
    let requestID: String?
}

struct NativeRootBackupStatus: Decodable {
    let running: Bool
    let operation: String
    let files: Int
    let bytes: Int64
    let lastError: String?
    let lastSnapshot: String?
    let restoredMetadata: String?
}

private struct RootBackupReply: Decodable {
    let rootID: String
    let generation: UInt64
    let status: NativeRootBackupStatus
}

/// A separate model keeps this developer preview out of the established
/// single-folder flow. All requests use the native parent's private pipe.
@MainActor
final class NativeRootsModel: ObservableObject {
    let enabled: Bool
    @Published private(set) var connected = false
    @Published private(set) var roots: [NativeSharedRoot] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var backupStatus: NativeRootBackupStatus?
    @Published private(set) var legacyMigrationPreview: NativeLegacyMigrationPreview?
    @Published var selectedID = ""
    private var sender: ((String) throws -> Void)?
    private var pollTask: Task<Void, Never>?
    private var responseDeadline: Task<Void, Never>?
    private var pendingRequestID: String?

    var selected: NativeSharedRoot? { roots.first { $0.rootID == selectedID && !$0.compatibility } }
    var legacyRoot: NativeSharedRoot? { roots.first { $0.compatibility } }
    var additionalRoots: [NativeSharedRoot] { roots.filter { !$0.compatibility } }

    init(enabled: Bool) { self.enabled = enabled }

    func connect(send: @escaping (String) throws -> Void) {
        guard enabled else { return }
        sender = send
        connected = true
        message = nil
        refresh()
    }

    func disconnect() {
        sender = nil
        connected = false
        busy = false
        backupStatus = nil
        legacyMigrationPreview = nil
        pollTask?.cancel()
        pollTask = nil
        responseDeadline?.cancel()
        responseDeadline = nil
        pendingRequestID = nil
    }

    func refresh() { send("list") }

    /// Private IPC only: does not migrate, remap grants, or write metadata.
    /// An unverified physical root must never be treated as promotion-ready.
    func previewLegacyMigration() {
        guard enabled, connected, !busy else { return }
        legacyMigrationPreview = nil
        send("migration-preview")
    }

    func verifyLegacyRoot() {
        guard enabled, connected, !busy, let legacyRoot, legacyRoot.pending else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "核实原共享目录的物理身份？"
        alert.informativeText = "仅用原单目录设置中已经选定、仍在线的同一个物理文件夹核对。不会重新选择磁盘、复制用户权限、移动原片或迁移数据库。如果原目录尚未在单目录设置中重新确认，请先完成原设置。"
        alert.addButton(withTitle: "核实原目录")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        send("legacy-verify", root: legacyRoot)
    }

    func selectionChanged() {
        backupStatus = nil
        message = nil
        pollTask?.cancel()
        pollTask = nil
        if let selected { send("backup-status", root: selected) }
    }

    func addFolder() {
        guard connected, !busy else { return }
        let panel = folderPanel(title: "选择一个额外共享目录", prompt: "添加目录")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        send("add", path: url.path, name: url.lastPathComponent)
    }

    func reconnectSelected() {
        guard let selected, connected, !busy else { return }
        let panel = folderPanel(title: "重新选择“\(selected.name)”所在的目录", prompt: "确认目录")
        panel.directoryURL = URL(fileURLWithPath: selected.path).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "将“\(selected.name)”连接到所选目录？"
        alert.informativeText = "此操作只允许重新连接原来的物理目录（可更换挂载路径）。如果换成另一块盘或新文件夹，必须单独添加共享目录并重新授予成员权限，以免旧账号权限暴露新文件。原目录文件不会删除。"
        alert.addButton(withTitle: "确认连接")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        send("rebind", root: selected, path: url.path)
    }

    func removeSelected() {
        guard let selected, connected, !busy else { return }
        let alert = NSAlert()
        alert.messageText = "移除“\(selected.name)”的共享登记？"
        alert.informativeText = "目录中的原文件会保留。成员将无法再通过轻屿访问此目录。正在使用中的目录需要等待任务结束。"
        alert.addButton(withTitle: "移除登记")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        send("remove", root: selected)
    }

    func startBackup() {
        guard let selected, selected.online, connected, !busy else { return }
        let panel = folderPanel(title: "选择独立的备份目的地", prompt: "备份到这里")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        send("backup-start", root: selected, path: url.path)
    }

    func stageRestore() {
        guard let selected, selected.online, connected, !busy else { return }
        let panel = folderPanel(title: "选择这个目录的轻屿备份快照", prompt: "验证并提取副本")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "检查备份并提取到独立目录？"
        alert.informativeText = "只接受与当前共享目录绑定一致的快照。已有原文件不会覆盖；数据库将先提取到隔离目录，不会自动替换当前账号与相册。"
        alert.addButton(withTitle: "检查并提取")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        send("backup-restore", root: selected, path: url.path)
    }

    func cancelBackup() {
        if let selected { send("backup-cancel", root: selected) }
    }

    func consume(_ encoded: String) {
        guard enabled, connected, encoded.utf8.count <= 180_000,
              let data = Self.decodePayload(encoded),
              let header = try? JSONDecoder().decode(RootReplyHeader.self, from: data),
              header.schemaVersion == 1, let requestID = header.requestID,
              requestID == pendingRequestID else { return }
        pendingRequestID = nil
        responseDeadline?.cancel()
        responseDeadline = nil
        busy = false
        if let error = header.error {
            message = Self.errorMessage(error)
            return
        }
        if header.operation == "migration-preview" {
            guard let reply = try? JSONDecoder().decode(RootReply<NativeLegacyMigrationPreview>.self, from: data),
                  let preview = reply.result, !preview.canApply else {
                message = "迁移预览无法安全读取，旧数据和权限未被修改。"
                return
            }
            legacyMigrationPreview = preview
            message = preview.physicalRootVerified
                ? "旧目录物理身份已核实。当前仅提供只读影响预览；迁移功能尚未开放。"
                : "旧目录尚未验证为原来的物理文件夹，已阻止自动继承所有历史权限和数据。"
            return
        }
        if header.operation == "list" {
            guard let reply = try? JSONDecoder().decode(RootReply<[NativeSharedRoot]>.self, from: data),
                  let items = reply.result, items.count <= 16 else {
                message = "无法读取共享目录列表，请重试。"
                return
            }
            let previousID = selected?.rootID
            let previousGeneration = selected?.generation
            roots = items
            legacyMigrationPreview = nil
            if !additionalRoots.contains(where: { $0.rootID == selectedID }) {
                selectedID = additionalRoots.first?.rootID ?? ""
                backupStatus = nil
            }
            if previousID == selected?.rootID && previousGeneration != selected?.generation {
                selectionChanged()
            }
            return
        }
        if header.operation.hasPrefix("backup-") {
            guard let reply = try? JSONDecoder().decode(RootReply<RootBackupReply>.self, from: data),
                  let result = reply.result,
                  let selected, result.rootID == selected.rootID,
                  result.generation == selected.generation else { return }
            let wasRunning = backupStatus?.running == true
            backupStatus = result.status
            if let error = result.status.lastError, !error.isEmpty {
                message = "备份或提取未完成。原文件会保留，请检查磁盘连接、空间与目录权限后重试。"
            } else if result.status.running {
                message = result.status.operation == "restore" ? "正在检查备份并提取独立副本…" : "正在备份所选目录…"
            } else if wasRunning || header.operation != "backup-status" {
                message = result.status.operation == "restore" ? "副本提取已结束，已有原文件保留。" : "备份任务已结束，可在访达中核对结果。"
            }
            updatePolling(running: result.status.running)
            return
        }
        message = header.operation == "remove" ? "已移除共享登记，原文件保留。" : "共享目录已更新。请在 Web 中为成员单独授权。"
        legacyMigrationPreview = nil
        refresh()
    }

    private func send(_ operation: String, root: NativeSharedRoot? = nil, path: String? = nil, name: String? = nil) {
        guard connected, !busy, let sender else { return }
        let requestID = UUID().uuidString.lowercased()
        var request: [String: Any] = ["requestID": requestID]
        if let root { request["rootID"] = root.rootID; request["generation"] = root.generation }
        if let path { request["path"] = path }
        if let name { request["name"] = name }
        var command = "roots " + operation
        guard let data = try? JSONSerialization.data(withJSONObject: request), data.count <= 6000 else { return }
        command += " " + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        do {
            pendingRequestID = requestID
            try sender(command + "\n")
            busy = true
            responseDeadline?.cancel()
            responseDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(18))
                guard !Task.isCancelled, let self, self.pendingRequestID == requestID else { return }
                self.pendingRequestID = nil
                self.busy = false
                self.message = "目录操作尚未确认。请刷新状态后再操作，不要重复提交。"
            }
        } catch {
            message = "无法连接本机服务，请检查轻屿是否仍在运行。"
            disconnect()
        }
    }

    private func updatePolling(running: Bool) {
        if !running { pollTask?.cancel(); pollTask = nil; return }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, let selected = self.selected else { return }
                self.send("backup-status", root: selected)
            }
        }
    }

    private func folderPanel(title: String, prompt: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel
    }

    private static func decodePayload(_ encoded: String) -> Data? {
        var value = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
    }

    private static func errorMessage(_ code: String) -> String {
        switch code {
        case "root_registry_overlap": return "所选目录与已有共享目录或备份目的地重叠，请选择独立目录。"
        case "root_registry_busy": return "目录仍被任务使用，或已达到目录数量上限。请等待任务结束后重试。"
        case "root_registry_stale", "root_registry_unknown": return "共享目录已变化，请刷新列表后重试。"
        case "root_registry_other_folder_requires_add": return "不能将现有共享编号连接到另一文件夹或硬盘：旧成员授权会泄露新数据。请新增独立目录，并在 Web 中重新授权。"
        case "root_registry_offline": return "无法确认原磁盘与目录，请检查连接后重新选择。"
        case "root_registry_persistence_uncertain_restart_required": return "目录设置的保存结果尚未确认。请重新启动轻屿后检查状态。"
        case "root_registry_path_not_allowed": return "此目录不能共享。请使用主目录或外置盘内的独立文件夹。"
        default: return "目录操作未完成，请检查磁盘连接、空间和权限后重试。"
        }
    }
}
