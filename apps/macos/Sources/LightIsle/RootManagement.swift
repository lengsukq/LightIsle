import AppKit
import Foundation
import SwiftUI

struct NativeSharedRoot: Decodable, Identifiable, Equatable {
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

struct NativeRootMaintenance: Decodable, Equatable {
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

// The owner's native controller is the only place allowed to register,
// switch, rebind, or remove physical storage directories.
@MainActor
final class NativeRootsModel: ObservableObject {
    let enabled: Bool
    @Published private(set) var connected = false
    @Published private(set) var roots: [NativeSharedRoot] = []
    @Published private(set) var busy = false
    @Published var message: String?
    @Published var selectedID = ""
    /// The containing Mac app owns the FSEvents watcher for the selected
    /// RootRegistry default, not for the retired shared-root path.
    var onDefaultChanged: ((NativeSharedRoot?) -> Void)?
    var onRootsChanged: (([NativeSharedRoot]) -> Void)?

    private struct MutationAttempt {
        let operation: String
        let root: NativeSharedRoot?
        let path: String?
        let name: String?
        let autoRepair: Bool
        var retried: Bool
    }

    private var sender: ((String) throws -> Void)?
    private var pendingID: String?
    private var pendingOperation: String?
    private var deadline: Task<Void, Never>?
    private var permissionChecking = false
    private var lastMutation: MutationAttempt?
    private var verifyCompletion: ((Bool, String?) -> Void)?

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
        deadline?.cancel()
        deadline = nil
        pendingID = nil
        pendingOperation = nil
        permissionChecking = false
        lastMutation = nil
        let completion = verifyCompletion
        verifyCompletion = nil
        sender = nil
        connected = false
        busy = false
        roots = []
        onRootsChanged?([])
        onDefaultChanged?(nil)
        completion?(false, "连接已断开。")
    }

    func refresh() { send("list") }
    func selectionChanged() { message = nil }

    func verifyAccess(
        path: String,
        autoRepairOnDenied: Bool = true,
        onComplete: ((Bool, String?) -> Void)? = nil
    ) {
        let cleanPath = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().path
        guard connected && !busy && !permissionChecking, !cleanPath.isEmpty else {
            onComplete?(false, "后台目录操作正在进行中，请稍候重试。")
            return
        }
        verifyCompletion = onComplete
        send("verify-access", path: cleanPath, autoRepair: autoRepairOnDenied)
    }

    func selectFolderAndSwitch(onVolume volume: HostVolume? = nil, preferVolumes: Bool = false) {
        guard connected && !busy && !permissionChecking else { return }
        let panel = folderPanel("选择默认 NAS 存储文件夹（支持外置硬盘）", "切换到此目录", preferVolumes: preferVolumes)
        if let volume {
            panel.directoryURL = URL(fileURLWithPath: volume.mount, isDirectory: true)
            panel.message = "请选择「\(volume.name)」磁盘中的专用文件夹（若直接选整块硬盘，可自动创建 LightIsle 专用目录）。"
        } else {
            panel.message = "已登记的目录直接切换；新目录先安全登记（若直接选择外置硬盘根目录，可自动创建 LightIsle 专用文件夹）。"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        permissionChecking = true
        Task { @MainActor [weak self] in
            defer { self?.permissionChecking = false }
            guard let self,
                  let canonical = await self.resolveSelectedVolumeFolder(url, requiredVolume: volume),
                  self.connected && !self.busy else { return }
            let alert = NSAlert()
            alert.messageText = "单独切换默认存储目录？"
            alert.informativeText = "目标：\(canonical.path)\n\n仅修改默认 rootID。旧磁盘和文件保持不变，也不会复制旧成员授权。切换后可在「个人空间」统一管理各分类目录与跨盘数据迁移。"
            alert.addButton(withTitle: "确认切换")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn, self.connected && !self.busy else { return }
            self.send("select-folder", path: canonical.path, name: canonical.lastPathComponent)
        }
    }

    func addFolder(onVolume volume: HostVolume? = nil, preferVolumes: Bool = false) {
        guard connected && !busy && !permissionChecking else { return }
        let panel = folderPanel("添加存储目录（支持外置硬盘）", "添加目录", preferVolumes: preferVolumes)
        if let volume {
            panel.directoryURL = URL(fileURLWithPath: volume.mount, isDirectory: true)
            panel.message = "请选择“\(volume.name)”磁盘中的专用文件夹（若直接选择整块磁盘，可自动创建 LightIsle 专用目录）。"
        } else {
            panel.message = "请选择外置硬盘或本机中的专用文件夹（若直接选择外置硬盘根目录，可自动创建 LightIsle 专用目录）。"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        permissionChecking = true
        Task { @MainActor [weak self] in
            defer { self?.permissionChecking = false }
            guard let self,
                  let selectedURL = await self.resolveSelectedVolumeFolder(url, requiredVolume: volume),
                  self.connected && !self.busy else { return }
            self.send("add", path: selectedURL.path, name: selectedURL.lastPathComponent)
        }
    }

    private func resolveSelectedVolumeFolder(_ rawURL: URL, requiredVolume: HostVolume? = nil) async -> URL? {
        let canonical = rawURL.resolvingSymlinksInPath()
        let components = canonical.pathComponents
        if canonical.path == "/" || canonical.path == "/Volumes" {
            message = "请选择具体硬盘或专用文件夹，不能直接使用系统根目录。"
            return nil
        }
        var targetURL = canonical
        if components.count == 3 && components[1] == "Volumes" {
            let diskName = components[2]
            let suggestedURL = canonical.appendingPathComponent("LightIsle", isDirectory: true)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "在外置硬盘「\(diskName)」上使用专用文件夹？"
            alert.informativeText = """
            为避免直接接管整块外置硬盘根目录、保护盘内其他无关文件，轻屿需要使用硬盘内的专用子文件夹。

            是否直接使用（或自动新建）：
            \(suggestedURL.path)
            """
            alert.addButton(withTitle: "使用「LightIsle」专用文件夹")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let access = await StoragePermissionHelper.ensureDirectoryWritable(
                suggestedURL,
                reason: "在外置硬盘「\(diskName)」上创建并使用 LightIsle 专用文件夹需要读写权限。"
            )
            guard access.ok else {
                message = access.errorMessage ?? "未获得外置硬盘目录读写权限。"
                return nil
            }
            targetURL = suggestedURL.resolvingSymlinksInPath()
        } else {
            let access = await StoragePermissionHelper.ensureDirectoryWritable(
                targetURL,
                reason: "登记并使用存储目录「\(targetURL.lastPathComponent)」需要读写权限。"
            )
            guard access.ok else {
                message = access.errorMessage ?? "未获得存储目录读写权限。"
                return nil
            }
        }
        if let requiredVolume {
            let base = URL(fileURLWithPath: requiredVolume.mount).resolvingSymlinksInPath().path
            guard targetURL.path.hasPrefix(base + "/") else {
                message = "请在选定磁盘内选择专用文件夹，而不是其他存储位置。"
                return nil
            }
        }
        return targetURL
    }

    func selectDefaultFolder(path: String, name: String, confirmSwitch: Bool = false) {
        guard connected && !busy && !permissionChecking else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let components = url.pathComponents
        if url.path == "/Volumes" || (components.count == 3 && components[1] == "Volumes") {
            message = "请选择外置硬盘内的专用文件夹，不能直接共享整块磁盘。"
            return
        }
        var operation = "select-folder"
        if confirmSwitch, let existing = defaultRoot, existing.path != url.path {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "切换默认主存储，还是仅添加为目标盘？"
            alert.informativeText = """
            新目录：\(url.path)
            当前默认主存储：\(existing.path)

            • 仅添加为目标硬盘（推荐）：保留原主存储上的「图库 / PhonePhotos」及共享文件可见，同时可在下方将此硬盘分配给个人空间或执行换盘迁移。
            • 同时设为默认主存储：仅更改默认主存储指向，不会移动或删除原目录中的照片、相册和文件。
            """
            alert.addButton(withTitle: "仅添加为目标硬盘（推荐）")
            alert.addButton(withTitle: "同时设为默认主存储")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                operation = "add"
            } else if response != .alertSecondButtonReturn {
                return
            }
        }
        permissionChecking = true
        Task { @MainActor [weak self] in
            defer { self?.permissionChecking = false }
            let access = await StoragePermissionHelper.ensureDirectoryWritable(
                url,
                reason: "创建并启用存储目录「\(url.lastPathComponent)」需要读写权限。"
            )
            guard let self else { return }
            guard access.ok else {
                self.message = access.errorMessage ?? "无法创建或访问该目录。"
                return
            }
            guard self.connected && !self.busy else { return }
            self.send(operation, path: url.path, name: name.isEmpty ? url.lastPathComponent : name)
        }
    }

    func addPresetFolder(path: String, name: String) {
        guard connected && !busy && !permissionChecking else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let components = url.pathComponents
        if url.path == "/Volumes" || (components.count == 3 && components[1] == "Volumes") {
            message = "请选择外置硬盘内的专用文件夹，不能直接共享整块磁盘。"
            return
        }
        permissionChecking = true
        Task { @MainActor [weak self] in
            defer { self?.permissionChecking = false }
            let access = await StoragePermissionHelper.ensureDirectoryWritable(
                url,
                reason: "在外置硬盘上创建并登记「\(url.lastPathComponent)」存储目录需要读写权限。"
            )
            guard let self else { return }
            guard access.ok else {
                self.message = access.errorMessage ?? "无法创建或访问该目录。"
                return
            }
            guard self.connected && !self.busy else { return }
            self.send("add", path: url.path, name: name.isEmpty ? url.lastPathComponent : name)
        }
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
        guard connected && !busy && !permissionChecking, let selected else { return }
        let panel = folderPanel("重新连接原硬盘上的目录", "确认目录")
        panel.directoryURL = URL(fileURLWithPath: selected.path).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "重新连接原来的物理目录？"
        alert.informativeText = "只允许原来的磁盘与目录。如果已换硬盘，请先移除旧登记，再添加新目录并重新分配成员空间。文件不会自动迁移。"
        alert.addButton(withTitle: "确认连接")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        permissionChecking = true
        Task { @MainActor [weak self] in
            defer { self?.permissionChecking = false }
            let access = await StoragePermissionHelper.ensureDirectoryWritable(
                url,
                reason: "重新连接外置存储目录「\(selected.name)」需要持久读写权限，以确保远程访问时无需在 Mac 旁确认。"
            )
            guard let self else { return }
            guard access.ok else {
                self.message = access.errorMessage ?? "未获得该存储目录的持久读写权限。"
                return
            }
            guard self.connected && !self.busy else { return }
            self.send("rebind", root: selected, path: url.resolvingSymlinksInPath().path)
        }
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
              let payload = Data(base64URLEncoded: encoded),
              let value = try? JSONDecoder().decode(RootReply<[NativeSharedRoot]>.self, from: payload),
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
    }

    private func consumeMutation(_ encoded: String) {
        struct Header: Decodable {
            let schemaVersion: Int
            let operation: String
            let requestID: String?
            let error: String?
        }
        guard let payload = Data(base64URLEncoded: encoded),
              let header = try? JSONDecoder().decode(Header.self, from: payload),
              header.schemaVersion == 1, header.requestID == pendingID,
              header.operation == pendingOperation,
              ["add", "remove", "rebind", "set-default", "select-folder", "verify-access"].contains(header.operation) else { return }
        let attempt = lastMutation
        finish()
        if let error = header.error {
            if error == "root_permission_denied",
               let attempt,
               attempt.autoRepair,
               !attempt.retried,
               let targetPath = attempt.path {
                permissionChecking = true
                Task { @MainActor [weak self] in
                    defer { self?.permissionChecking = false }
                    let access = await StoragePermissionHelper.requestReadWriteAccess(
                        forPath: targetPath,
                        reason: "轻屿后台服务（lightisled）需要该硬盘目录的持久读写权限，以确保后续远程访问时无需在 Mac 旁手动确认。"
                    )
                    guard let self else { return }
                    guard access.ok, self.connected && !self.busy else {
                        let msg = access.errorMessage ?? self.errorMessage("root_permission_denied")
                        self.message = msg
                        if attempt.operation == "verify-access" {
                            let cb = self.verifyCompletion
                            self.verifyCompletion = nil
                            cb?(false, msg)
                        }
                        return
                    }
                    self.send(
                        attempt.operation,
                        root: attempt.root,
                        path: attempt.path,
                        name: attempt.name,
                        autoRepair: attempt.autoRepair,
                        isRetry: true
                    )
                }
                return
            }
            let msg = errorMessage(error)
            message = msg
            if header.operation == "verify-access" {
                let cb = verifyCompletion
                verifyCompletion = nil
                cb?(false, msg)
            }
            return
        }
        if header.operation == "verify-access" {
            let okMsg = "已完成外置目录与后台服务读写权限预检，后续手机/网页远程使用无需在 Mac 旁授权。"
            message = okMsg
            let cb = verifyCompletion
            verifyCompletion = nil
            cb?(true, okMsg)
            return
        }
        message = header.operation == "remove"
            ? "已移除登记，原硬盘数据未删除。"
            : header.operation == "set-default"
            ? "默认 NAS 存储空间已更新。原数据和其他目录均未移动。"
            : header.operation == "select-folder"
            ? "默认 NAS 存储空间已更新并完成后台读写预检，后续远程访问无需在 Mac 旁授权。"
            : "存储目录已就绪并完成后台读写权限预检，后续远程使用或换盘迁移无需重复授权。"
        refresh()
    }

    private func finish() {
        deadline?.cancel()
        deadline = nil
        pendingID = nil
        pendingOperation = nil
        lastMutation = nil
        busy = false
    }

    private func send(
        _ operation: String,
        root: NativeSharedRoot? = nil,
        path: String? = nil,
        name: String? = nil,
        autoRepair: Bool = true,
        isRetry: Bool = false
    ) {
        guard connected && !busy, let sender,
              ["list", "add", "rebind", "remove", "set-default", "select-folder", "verify-access"].contains(operation) else { return }
        let id = UUID().uuidString.lowercased()
        var arguments: [String: Any] = ["requestID": id]
        if let root { arguments["rootID"] = root.rootID; arguments["generation"] = root.generation }
        if let path { arguments["path"] = path }
        if let name { arguments["name"] = name }
        guard let data = try? JSONSerialization.data(withJSONObject: arguments),
              data.count <= 6000 else { return }
        let encoded = data.base64URLEncodedString
        do {
            pendingID = id
            pendingOperation = operation
            if operation != "list" {
                lastMutation = MutationAttempt(
                    operation: operation,
                    root: root,
                    path: path,
                    name: name,
                    autoRepair: autoRepair,
                    retried: isRetry
                )
            }
            busy = true
            try sender("roots \(operation) \(encoded)\n")
            deadline?.cancel()
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(18))
                guard !Task.isCancelled, let self, self.pendingID == id else { return }
                let wasVerify = self.pendingOperation == "verify-access"
                self.finish()
                let timeoutMsg = "操作结果尚未确认，请刷新目录状态后再操作。"
                self.message = timeoutMsg
                if wasVerify {
                    let cb = self.verifyCompletion
                    self.verifyCompletion = nil
                    cb?(false, timeoutMsg)
                }
            }
        } catch {
            message = "无法连接本机服务，请检查 LightIsle 是否运行。"
            disconnect()
        }
    }

    private func folderPanel(_ title: String, _ prompt: String, preferVolumes: Bool = false) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if preferVolumes {
            let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            if FileManager.default.fileExists(atPath: volumesURL.path) {
                panel.directoryURL = volumesURL
            }
        }
        return panel
    }

    private func errorMessage(_ code: String) -> String {
        switch code {
        case "root_registry_offline": return "硬盘离线，请检查连接、供电与挂载，然后刷新重试。"
        case "root_registry_busy": return "当前目录正在使用，请结束相关任务后重试。"
        case "root_registry_overlap": return "此目录与现有存储空间重叠，请另选文件夹。"
        case "root_registry_stale", "root_registry_unknown": return "存储登记已变化，请刷新后重试。"
        case "root_registry_other_folder_requires_add": return "不能把旧目录绑定到另一块盘。请先移除旧登记再新增。"
        case "root_registry_invalid": return "所选目录无效，请重新选择专用文件夹。"
        case "root_permission_denied": return "后台服务缺少该目录的持久读写权限。请在系统「隐私与安全性 → 文件和文件夹」开启轻屿的「可移除宗卷」权限，或修复目录所有权后重试。"
        case "root_read_only": return "该硬盘当前为只读挂载（如 NTFS 格式），macOS 无法写入，请使用 APFS 或 ExFAT 格式硬盘。"
        default: return "目录操作失败（\(code)）。请检查连接并刷新状态。"
        }
    }
}
