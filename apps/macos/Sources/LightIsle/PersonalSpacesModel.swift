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

struct NativeStorageRootQuota: Decodable, Equatable {
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
    @Published var lastTransferResult: NativeStorageSwitchResult?
    @Published private(set) var lastCreatedUser: NativeSpaceUserAccount?
    @Published private(set) var lastCompletedOperation: String?

    private var writer: ((String) throws -> Void)?
    private var activeRequestID: String?
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

    func readStorageSwitch(userID: Int64, taskID: String? = nil, phase: String = "status") {
        guard !busy else { return }
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
        let encoded = jsonData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
        var padded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
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
        if let result = envelope.result {
            users = result.users
            roots = result.roots
            if let created = result.createdUser {
                lastCreatedUser = created
                selectedUserID = created.id
            } else if !users.contains(where: { $0.id == selectedUserID }), let first = users.first {
                selectedUserID = first.id
            }
        }
        if let errCode = envelope.error, !errCode.isEmpty {
            let baseError = humanizeSpacesError(errCode)
            if envelope.operation == "create-user", let created = envelope.result?.createdUser {
                errorMessage = "账号「\(created.username)」已创建成功，但初始存储空间分配未完成：\(baseError)"
            } else {
                errorMessage = baseError
            }
            return
        }
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
                    message = transfer.canResume == true
                        ? "切换尚未提交。请接回原来的两块盘，再重新核验并继续。"
                        : "任务中断。请检查两块硬盘和任务结果。"
                    if let path = transfer.reviewPath {
                        message? += " 核对位置：\(path)"
                    }
                case "cancelled":
                    message = "换盘任务已取消。"
                default:
                    errorMessage = humanizeSpacesError(transfer.error ?? "storage_switch_failed")
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
                default:
                    break
                }
            }
        }
    }

    private func humanizeSpacesError(_ code: String) -> String {
        switch code {
        case "account_already_exists":
            return "该用户名已存在，请更换其他名称。"
        case "storage_invalid_request":
            return "参数格式不正确（用户名需 3-32 位字母/数字/下划线，密码至少 12 位；子目录名不能包含特殊路径）。"
        case "storage_permission_denied":
            return "无权执行此操作（管理员默认无限配额，无需设置固定上限）。"
        case "storage_switch_task_not_found":
            return "该成员还没有换盘任务。"
        case "user_not_found":
            return "未找到目标用户。"
        case "root_not_found":
            return "未找到所选存储硬盘登记，请先在「存储位置」添加或刷新。"
        case "root_unavailable":
            return "目标或来源硬盘当前离线，请检查硬盘连接并确保在线后再操作。"
        case "root_generation_changed":
            return "硬盘连接代次已变化，请刷新后再执行操作。"
        case "storage_folder_conflict":
            return "目标目录已存在同名但内容不一致的文件，为保护数据未覆盖，请先检查目标目录。"
        case "storage_migration_verification_failed":
            return "源文件与目标文件的 SHA-256 核验不一致，已中止清理并保留全部源文件。"
        case "storage_quota_exceeded":
            return "目标硬盘配额不足以容纳待复制/迁移的文件，请先调高目标盘配额。"
        case "storage_switch_disk_full":
            return "目标盘可用空间不足。"
        case "storage_switch_size_limit":
            return "目录超过本次可安全切换的容量或文件数量限制。"
        case "storage_switch_unsupported_entry":
            return "目录内含链接或其他无法安全移动的项目。"
        case "storage_switch_busy":
            return "正在处理另一项换盘任务，请查看任务状态。"
        case "storage_accounting_conflict":
            return "来源目录存在未完成的上传预留，请先完成或清理上传后再执行迁移。"
        case "storage_migration_required":
            return "该分类目录已绑定到其他硬盘，请使用「更换存储硬盘（复制/迁移）」切换。"
        case "storage_remove_root_first":
            return "请先在「存储 → 存储位置」中移除该故障硬盘登记，再放弃旧分类绑定。"
        default:
            return "空间操作未完成（\(code)），请刷新后重试。"
        }
    }
}
