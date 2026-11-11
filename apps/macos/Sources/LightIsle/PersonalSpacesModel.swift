import Foundation
import SwiftUI

struct NativeSpaceUserAccount: Decodable, Identifiable, Equatable {
    let id: Int64
    let username: String
    let role: String
    let enabled: Bool
    let createdAt: Int64

    var isAdmin: Bool { role == "admin" }
}

struct NativeStorageLocation: Decodable, Equatable, Hashable {
    let category: String
    let rootID: String
    let rootGeneration: UInt64
    let relativePath: String
}

struct NativeStorageRootQuota: Decodable, Identifiable, Equatable {
    var id: String { "\(rootID)-\(rootGeneration)" }
    let rootID: String
    let rootGeneration: UInt64
    let quotaBytes: Int64?
    let accountedBytes: Int64
    let reservedBytes: Int64
}

struct NativeStoragePolicy: Decodable, Equatable {
    let userId: Int64
    let role: String?
    let unlimited: Bool?
    let quotaBytes: Int64?
    let rootQuotas: [NativeStorageRootQuota]
    let locations: [NativeStorageLocation]
    let enforcement: String
    let accountedBytes: Int64
    let reservedBytes: Int64
    let usageComplete: Bool

    var isUnlimited: Bool { unlimited == true || role == "admin" }
}

struct NativeSpaceUserEntry: Decodable, Identifiable, Equatable {
    var id: Int64 { user.id }
    let user: NativeSpaceUserAccount
    let policy: NativeStoragePolicy
}

struct NativeSpaceRootInfo: Decodable, Identifiable, Equatable {
    var id: String { rootID }
    let rootID: String
    let generation: UInt64
    let name: String
    let path: String
    let online: Bool
    let isDefault: Bool
    let filesystemTotalBytes: UInt64?
    let filesystemAvailableBytes: UInt64?

    func isAvailable(for expectedGeneration: UInt64) -> Bool {
        online && generation == expectedGeneration
    }

    func statusText(for expectedGeneration: UInt64, includeName: Bool = false) -> String {
        let state: String
        if !online {
            state = "离线"
        } else if generation != expectedGeneration {
            state = "重连批次待同步"
        } else {
            state = "在线"
        }
        return includeName ? "\(name) · \(state)" : state
    }
}

struct NativeStorageSwitchShare: Decodable, Equatable {
    let kind: String
    let path: String
    let ownerID: Int64
    let memberID: Int64?

    var description: String {
        if let memberID { return "共享相册：\(path)（接收成员 #\(memberID)）" }
        return "公开链接：\(path)"
    }
}

struct NativeStorageSwitchResult: Decodable, Equatable {
    let taskID: String
    let error: String?
    let errorDetail: String?
    let affectedShares: Int
    let affectedShareItems: [NativeStorageSwitchShare]?

    var isRunning: Bool {
        phase == "queued" || phase == "copying" || phase == "committing"
    }
    let mode: String
    let phase: String
    let totalFiles: Int?
    let totalBytes: Int64?
    let copiedFiles: Int
    let copiedBytes: Int64
    let verifiedFiles: Int
    let deletedSourceFiles: Int
    let readyToCleanup: Bool
    let canResume: Bool?
    let canCancel: Bool?
    let reviewPath: String?
    let policy: NativeStoragePolicy
}

private struct NativeSpacesOverviewPayload: Decodable {
    let users: [NativeSpaceUserEntry]
    let roots: [NativeSpaceRootInfo]
    let createdUser: NativeSpaceUserAccount?
    let transfer: NativeStorageSwitchResult?
}

private struct NativeSpacesEnvelope: Decodable {
    let schemaVersion: Int
    let operation: String
    let requestID: String?
    let result: NativeSpacesOverviewPayload?
    let error: String?
}

private struct NativeSpacesRequestPayload: Encodable {
    var requestID: String
    var userID: Int64?
    var username: String?
    var password: String?
    var role: String?
    var enabled: Bool?
    var rootID: String?
    var generation: UInt64?
    var quotaBytes: Int64?
    var categories: [String]?
    var subdirectories: [String]?
    var category: String?
    var sourceRootID: String?
    var sourceGeneration: UInt64?
    var targetRootID: String?
    var targetGeneration: UInt64?
    var targetQuotaBytes: Int64?
    var mode: String?
    var phase: String?
    var taskID: String?
}

@MainActor
final class NativeSpacesModel: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var users: [NativeSpaceUserEntry] = []
    @Published private(set) var roots: [NativeSpaceRootInfo] = []
    @Published var selectedUserID: Int64 = 0
    @Published var message: String?
    @Published var errorMessage: String?
    @Published private(set) var lastErrorCode: String?
    @Published var lastTransferResult: NativeStorageSwitchResult?
    @Published private(set) var lastCreatedUser: NativeSpaceUserAccount?
    @Published private(set) var lastCompletedOperation: String?

    private var writer: ((String) throws -> Void)?
    private var activeRequestID: String?
    private var silentIfTaskMissing = false
    private var timeoutTask: Task<Void, Never>?
    private var transferPoll: Task<Void, Never>?

    var selectedEntry: NativeSpaceUserEntry? {
        users.first(where: { $0.id == selectedUserID }) ?? users.first
    }

    var onlineRoots: [NativeSpaceRootInfo] {
        roots.filter(\.online)
    }

    var systemAppDataPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Library/Application Support")
        return base + "/LightIsle"
    }

    func rootInfo(for rootID: String) -> NativeSpaceRootInfo? {
        roots.first(where: { $0.rootID == rootID })
    }

    func connect(writer: @escaping (String) throws -> Void) {
        self.writer = writer
        connected = true
        refresh()
    }

    func disconnect() {
        transferPoll?.cancel()
        transferPoll = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        writer = nil
        activeRequestID = nil
        connected = false
        busy = false
    }

    func refresh() {
        send(operation: "list", payload: NativeSpacesRequestPayload(requestID: UUID().uuidString))
    }

    func clearLastOperationState() {
        lastCreatedUser = nil
        lastCompletedOperation = nil
        errorMessage = nil
    }

    func createUser(
        username: String,
        password: String,
        role: String = "member",
        rootID: String?,
        generation: UInt64?,
        quotaBytes: Int64?,
        categories: [String],
        subdirectories: [String]
    ) {
        send(
            operation: "create-user",
            payload: NativeSpacesRequestPayload(
                requestID: UUID().uuidString,
                username: username,
                password: password,
                role: role,
                rootID: rootID,
                generation: generation,
                quotaBytes: quotaBytes,
                categories: categories.isEmpty ? nil : categories,
                subdirectories: subdirectories.isEmpty ? nil : subdirectories
            )
        )
    }

    func allocateSpace(
        userID: Int64,
        rootID: String,
        generation: UInt64,
        quotaBytes: Int64?,
        categories: [String],
        subdirectories: [String]
    ) {
        send(
            operation: "allocate",
            payload: NativeSpacesRequestPayload(
                requestID: UUID().uuidString,
                userID: userID,
                rootID: rootID,
                generation: generation,
                quotaBytes: quotaBytes,
                categories: categories,
                subdirectories: subdirectories
            )
        )
    }

    func setRootQuota(userID: Int64, rootID: String, generation: UInt64, quotaBytes: Int64) {
        send(
            operation: "set-quota",
            payload: NativeSpacesRequestPayload(
                requestID: UUID().uuidString,
                userID: userID,
                rootID: rootID,
                generation: generation,
                quotaBytes: quotaBytes
            )
        )
    }

    func switchRoot(
        userID: Int64,
        categories: [String],
        sourceRootID: String,
        sourceGeneration: UInt64,
        targetRootID: String,
        targetGeneration: UInt64,
        targetQuotaBytes: Int64?,
        mode: String,
        phase: String
    ) {
        lastTransferResult = nil
        send(
            operation: "switch-root",
            payload: NativeSpacesRequestPayload(
                requestID: UUID().uuidString,
                userID: userID,
                categories: categories,
                sourceRootID: sourceRootID,
                sourceGeneration: sourceGeneration,
                targetRootID: targetRootID,
                targetGeneration: targetGeneration,
                targetQuotaBytes: targetQuotaBytes,
                mode: mode,
                phase: phase,
                taskID: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            )
        )
    }

    func readStorageSwitch(userID: Int64, taskID: String? = nil, phase: String = "status", silentIfMissing: Bool = false) {
        guard !busy else { return }
        silentIfTaskMissing = silentIfMissing && phase == "status"
        send(operation: "switch-root", payload: NativeSpacesRequestPayload(
            requestID: UUID().uuidString,
            userID: userID,
            phase: phase,
            taskID: taskID
        ))
    }

    private func scheduleTransferPoll(_ transfer: NativeStorageSwitchResult) {
        transferPoll?.cancel()
        transferPoll = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self, self.connected, self.lastTransferResult?.taskID == transfer.taskID else { return }
            self.readStorageSwitch(userID: transfer.policy.userId, taskID: transfer.taskID)
        }
    }

    func abandonBinding(userID: Int64, rootID: String, generation: UInt64, category: String?) {
        send(
            operation: "abandon",
            payload: NativeSpacesRequestPayload(
                requestID: UUID().uuidString,
                userID: userID,
                rootID: rootID,
                generation: generation,
                category: category
            )
        )
    }

    func setUserEnabled(userID: Int64, enabled: Bool) {
        send(
            operation: "set-user-enabled",
            payload: NativeSpacesRequestPayload(
                requestID: UUID().uuidString,
                userID: userID,
                enabled: enabled
            )
        )
    }

    func resetUserPassword(userID: Int64, newPassword: String) {
        send(
            operation: "reset-user-password",
            payload: NativeSpacesRequestPayload(
                requestID: UUID().uuidString,
                userID: userID,
                password: newPassword
            )
        )
    }

    private func send(operation: String, payload: NativeSpacesRequestPayload) {
        guard !busy else { return }
        guard let writer, connected else {
            errorMessage = "Go Core 尚未就绪，请稍后重试。"
            return
        }
        guard let jsonData = try? JSONEncoder().encode(payload) else {
            errorMessage = "请求参数编码失败。"
            return
        }
        let encoded = jsonData.base64URLEncodedString
        do {
            errorMessage = nil
            busy = true
            activeRequestID = payload.requestID
            try writer("spaces \(operation) \(encoded)\n")
            startTimeout(for: payload.requestID)
        } catch {
            busy = false
            activeRequestID = nil
            errorMessage = "无法发送命令至 Go Core：\(error.localizedDescription)"
        }
    }

    private func startTimeout(for requestID: String) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, self.activeRequestID == requestID else { return }
            self.busy = false
            self.activeRequestID = nil
            self.errorMessage = "空间管理操作响应超时，请刷新状态后核对结果。"
        }
    }

    func consume(_ raw: String) {
        guard let data = Data(base64URLEncoded: raw),
              let envelope = try? JSONDecoder().decode(NativeSpacesEnvelope.self, from: data) else {
            busy = false
            errorMessage = "无法解析个人空间状态响应。"
            return
        }
        guard let active = activeRequestID, envelope.requestID == active else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        activeRequestID = nil
        busy = false
        let wasSilentStatus = silentIfTaskMissing
        silentIfTaskMissing = false
        if let result = envelope.result {
            users = result.users
            roots = result.roots
            if let transfer = result.transfer {
                lastTransferResult = transfer
            }
            if let created = result.createdUser {
                lastCreatedUser = created
                selectedUserID = created.id
            } else if !users.contains(where: { $0.id == selectedUserID }), let first = users.first {
                selectedUserID = first.id
            }
        }
        if let errCode = envelope.error, !errCode.isEmpty {
            if wasSilentStatus && errCode == "storage_switch_task_not_found" {
                lastErrorCode = nil
                errorMessage = nil
                return
            }
            lastErrorCode = errCode
            let baseError = humanizeSpacesError(
                errCode,
                detail: envelope.result?.transfer?.errorDetail,
                reviewPath: envelope.result?.transfer?.reviewPath
            )
            if envelope.operation == "create-user", let created = envelope.result?.createdUser {
                errorMessage = "账号「\(created.username)」已创建成功，但初始存储空间分配未完成：\(baseError)"
            } else {
                errorMessage = baseError
            }
            return
        }
        lastErrorCode = nil
        errorMessage = nil
        lastCompletedOperation = envelope.operation
        if let result = envelope.result {
            if let transfer = result.transfer {
                lastTransferResult = transfer
                switch transfer.phase {
                case "queued", "copying", "committing":
                    message = transfer.phase == "committing"
                        ? "正在切换空间并核对源盘…"
                        : "正在复制并核验，已复制 \(ByteCountFormatter.string(fromByteCount: transfer.copiedBytes, countStyle: .binary))。"
                    scheduleTransferPoll(transfer)
                case "verified":
                    message = "已核验 \(transfer.verifiedFiles) 个文件，影响 \(transfer.affectedShares) 项分享。"
                case "completed":
                    switch transfer.mode {
                    case "empty":
                        message = "已启用空白新目录，旧盘原件保留。"
                    case "copy":
                        message = "已复制并切换，旧盘原件保留。"
                    default:
                        message = "空间已切换，源文件可在旧盘的回收站恢复。"
                    }
                case "source_pending":
                    message = "空间已切换，源文件待处理。请核对旧盘与回收站。"
                case "interrupted":
                    lastErrorCode = transfer.error
                    if transfer.canResume == true {
                        message = "切换在发布阶段中断，原文件与已发布目录均保留。请确认两块盘在线后点击「重新核验并继续切换」。"
                    } else {
                        errorMessage = humanizeSpacesError(
                            transfer.error ?? "storage_switch_interrupted",
                            detail: transfer.errorDetail,
                            reviewPath: transfer.reviewPath
                        )
                    }
                case "cancelled":
                    message = "换盘任务已取消，原有目录与文件保持不变。"
                default:
                    lastErrorCode = transfer.error ?? "storage_switch_failed"
                    errorMessage = humanizeSpacesError(
                        transfer.error ?? "storage_switch_failed",
                        detail: transfer.errorDetail,
                        reviewPath: transfer.reviewPath
                    )
                }
            } else {
                switch envelope.operation {
                case "create-user":
                    message = "新成员账号与存储空间已创建。"
                case "allocate":
                    message = "存储目录与配额配置已保存。"
                case "set-quota":
                    message = "硬盘配额上限已更新。"
                case "abandon":
                    message = "已放弃旧离线硬盘登记绑定，现在可重新分配新硬盘。"
                case "set-user-enabled":
                    message = "成员账号启用状态已更新。"
                case "reset-user-password":
                    message = "成员密码已重置，该成员的旧登录会话已失效。"
                default:
                    break
                }
            }
        }
    }

    func humanizeSpacesError(_ code: String, detail: String? = nil, reviewPath: String? = nil) -> String {
        var text: String
        switch code {
        case "account_already_exists":
            text = "该用户名已存在，请更换其他名称。"
        case "storage_invalid_request":
            text = "参数格式不正确（用户名需 3-32 位字母/数字/下划线，密码至少 12 位；子目录名不能包含特殊路径）。"
        case "storage_permission_denied":
            text = "当前账号无权执行此操作。"
        case "storage_permission_os_denied":
            text = "macOS 拒绝读写目标或来源存储目录（原有文件未受损）。请点击下方「立即申请目录读写权限…」授权后再重试。"
        case "storage_switch_task_not_found":
            text = "该账号当前没有待处理的换盘任务。"
        case "user_not_found":
            text = "未找到目标用户。"
        case "root_not_found":
            text = "未找到所选存储硬盘登记，请先添加外置硬盘目录或刷新状态。"
        case "root_unavailable":
            text = "目标或来源硬盘当前离线（原有文件未受损）。请检查硬盘连接线、供电与访达挂载状态后再重试。"
        case "root_generation_changed":
            text = "硬盘连接批次已变化（可能重新拔插过），请刷新状态后再重试。"
        case "storage_folder_conflict":
            text = "目标硬盘的对应个人目录中已存在文件，为保护现有数据未覆盖。可在访达中检查目标目录或选择其他硬盘。"
        case "storage_migration_verification_failed":
            text = "源文件与目标文件的 SHA-256 校验不一致（可能在复制期间有文件被修改），已中止切换并完整保留全部源文件。"
        case "storage_quota_exceeded":
            text = "目标硬盘配额不足以容纳待复制/迁移的文件，请先调高目标盘配额上限。"
        case "storage_switch_disk_full":
            text = "目标硬盘剩余可用空间不足，无法安全完成复制（原有文件未受损）。请清理目标盘空间或更换其他硬盘。"
        case "storage_switch_size_limit":
            text = "目录超过单次安全切换的容量或文件数量上限，请先分批整理大目录。"
        case "storage_switch_unsupported_entry":
            text = "目录内含外部符号链接或特殊设备文件，为确保数据安全已中止切换（原有文件未受损）。"
        case "storage_switch_busy", "shared_directory_busy":
            text = "存在尚未确认或未完成的换盘任务（原有文件未受损）。请在下方查看当前任务详情，可继续确认完成或取消旧任务后再重新开始。"
        case "storage_switch_interrupted":
            text = "上一次换盘任务中断，原盘文件均安全保留。可点击「取消中断任务」释放预留后重新开始，或继续未完成的切换。"
        case "storage_switch_media_reassociation":
            text = "文件已安全复制到目标盘，但相册收藏或观看进度关联未完成。请核对两块硬盘在线后重试。"
        case "storage_accounting_conflict":
            text = "来源目录存在未完成的上传任务预留，请等待上传完成或清理后再执行换盘。"
        case "storage_migration_required":
            text = "该分类目录已绑定到其他硬盘，请使用「更换硬盘 / 迁移…」切换。"
        case "storage_remove_root_first":
            text = "请先在「存储 → 存储位置」中移除该故障硬盘登记，再放弃旧分类绑定。"
        case "storage_switch_failed":
            text = "换盘任务未完成，原盘文件均完整保留。"
        default:
            text = "空间操作未完成（\(code)），原盘数据未受影响。"
        }
        if let reviewPath, !reviewPath.isEmpty {
            text += "\n涉及目录：\(reviewPath)"
        }
        if let detail, !detail.isEmpty, detail != code {
            text += "\n底层诊断：\(detail)"
        }
        return text
    }
}
