import Foundation

enum QuotaValidationResult: Equatable {
    case unlimited
    case valid(bytes: Int64)
    case validWithWarning(bytes: Int64, warning: String)
    case invalid(message: String)

    var isValid: Bool {
        switch self {
        case .unlimited, .valid, .validWithWarning:
            return true
        case .invalid:
            return false
        }
    }

    var quotaBytes: Int64? {
        switch self {
        case .unlimited:
            return 0
        case .valid(let bytes), .validWithWarning(let bytes, _):
            return bytes
        case .invalid:
            return nil
        }
    }

    var errorMessage: String? {
        if case .invalid(let message) = self {
            return message
        }
        return nil
    }

    var warningMessage: String? {
        if case .validWithWarning(_, let warning) = self {
            return warning
        }
        return nil
    }
}

enum QuotaInputValidator {
    static let maxQuotaGiB: Int64 = 1_048_576
    static let bytesPerGiB: Int64 = 1 << 30

    static func validateGiB(_ raw: String, currentUsedBytes: Int64 = 0) -> QuotaValidationResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unlimited
        }
        guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let gib = Int64(trimmed),
              (0...maxQuotaGiB).contains(gib) else {
            return .invalid(message: "配额必须输入 0–1048576 之间的整数 GiB（0 或留空表示不限制）")
        }
        let (bytes, overflow) = gib.multipliedReportingOverflow(by: bytesPerGiB)
        guard !overflow, bytes >= 0 else {
            return .invalid(message: "配额数值超出安全范围（上限 1048576 GiB）")
        }
        if bytes == 0 {
            return .unlimited
        }
        if currentUsedBytes > 0 && bytes < currentUsedBytes {
            let formattedUsed = ByteCountFormatter.string(fromByteCount: currentUsedBytes, countStyle: .file)
            return .validWithWarning(
                bytes: bytes,
                warning: "设定额度低于当前已计入用量（\(formattedUsed)），保存后该盘新增上传将受阻，已有文件不会删除。"
            )
        }
        return .valid(bytes: bytes)
    }
}

enum FieldValidationStatus: Equatable {
    case empty
    case valid(String)
    case invalid(String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .empty:
            return nil
        case .valid(let text), .invalid(let text):
            return text
        }
    }
}

enum AccountInputValidator {
    static let minUsernameLength = 3
    static let maxUsernameLength = 32
    static let minPasswordLength = 12
    static let maxPasswordLength = 256

    static func validateUsername(_ raw: String) -> FieldValidationStatus {
        guard !raw.isEmpty else {
            return .empty
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != raw {
            return .invalid("账号名称首尾不能包含空格")
        }
        guard (minUsernameLength...maxUsernameLength).contains(trimmed.count) else {
            return .invalid("需 \(minUsernameLength)–\(maxUsernameLength) 位字母、数字、点(.)、下划线(_)或连字符(-)")
        }
        let allowed = trimmed.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                return true
            default:
                return false
            }
        }
        guard allowed else {
            return .invalid("仅允许英文字母、数字、点(.)、下划线(_)或连字符(-)")
        }
        return .valid("账号格式可用")
    }

    static func validatePassword(_ raw: String) -> FieldValidationStatus {
        guard !raw.isEmpty else {
            return .empty
        }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines) != raw {
            return .invalid("密码首尾不能包含空格")
        }
        if raw.count < minPasswordLength {
            return .invalid("还差 \(minPasswordLength - raw.count) 位（需至少 \(minPasswordLength) 位）")
        }
        if raw.count > maxPasswordLength {
            return .invalid("密码长度不能超过 \(maxPasswordLength) 位")
        }
        return .valid("长度符合要求（\(raw.count) 位）")
    }
}

enum SpaceCategoryPresentation {
    static func title(for category: String) -> String {
        switch category {
        case "files":
            return "文件"
        case "photos":
            return "相册"
        case "videos":
            return "影视"
        default:
            return category
        }
    }

    static func icon(for category: String) -> String {
        switch category {
        case "files":
            return "folder"
        case "photos":
            return "photo.on.rectangle"
        case "videos":
            return "film"
        default:
            return "externaldrive"
        }
    }

    static func detailLabel(for category: String) -> String {
        "\(title(for: category))（\(category)）"
    }

    static func enforcementDescription(_ enforcement: String) -> String {
        switch enforcement {
        case "enforced", "active":
            return "全入口硬配额生效"
        default:
            return "部分入口统计生效（实验阶段）"
        }
    }
}

struct StorageSwitchStagePresentation: Equatable {
    let stepIndex: Int
    let totalSteps: Int
    let title: String
    let subtitle: String
    let fraction: Double?

    static func describe(
        phase: String,
        mode: String,
        copiedBytes: Int64,
        totalBytes: Int64?,
        verifiedFiles: Int,
        totalFiles: Int?,
        deletedSourceFiles: Int
    ) -> StorageSwitchStagePresentation {
        let totalB = totalBytes ?? 0
        let totalF = totalFiles ?? 0
        let fraction: Double? = totalB > 0 ? min(max(Double(copiedBytes) / Double(totalB), 0), 1) : nil
        let copiedStr = ByteCountFormatter.string(fromByteCount: copiedBytes, countStyle: .binary)
        let totalStr = totalB > 0 ? ByteCountFormatter.string(fromByteCount: totalB, countStyle: .binary) : nil
        let filesSummary = totalF > 0 ? "\(verifiedFiles) / \(totalF) 个文件" : "\(verifiedFiles) 个文件"
        let bytesSummary = totalStr.map { "\(copiedStr) / \($0)" } ?? copiedStr

        switch phase {
        case "queued":
            return StorageSwitchStagePresentation(
                stepIndex: 1,
                totalSteps: 5,
                title: "第 1/5 步 · 扫描源目录并预留空间",
                subtitle: "正在统计待切换目录的文件数量与总容量…",
                fraction: 0.05
            )
        case "copying":
            return StorageSwitchStagePresentation(
                stepIndex: 2,
                totalSteps: 5,
                title: "第 2/5 步 · 复制并逐文件 SHA-256 核验",
                subtitle: "已复制 \(bytesSummary) · 已核验 \(filesSummary)",
                fraction: fraction
            )
        case "verified":
            let emptyPersonalWarning = totalF == 0 && verifiedFiles == 0 && mode != "empty"
            return StorageSwitchStagePresentation(
                stepIndex: 3,
                totalSteps: 5,
                title: emptyPersonalWarning ? "第 3/5 步 · 源个人专属目录为 0 个文件，请确认" : "第 3/5 步 · 核验通过，等待管理员确认切换",
                subtitle: emptyPersonalWarning
                    ? "源盘 Users 个人专属目录内共 0 个文件。若此前照片或文件保存在原盘根层、「图库」或「PhonePhotos」中，本次仅切换空个人目录（原盘数据不会丢失）。"
                    : "已完成 \(filesSummary)（\(bytesSummary)）的 SHA-256 校验，源盘文件尚未改动。",
                fraction: 1.0
            )
        case "committing":
            return StorageSwitchStagePresentation(
                stepIndex: 4,
                totalSteps: 5,
                title: "第 4/5 步 · 原子切换绑定并同步媒体进度",
                subtitle: "正在发布目标目录、迁移相册/影视记录并更新分类绑定…",
                fraction: 1.0
            )
        case "completed":
            let suffix: String
            switch mode {
            case "empty":
                suffix = "已在新硬盘启用空白目录，旧盘原件保留。"
            case "copy":
                suffix = totalF == 0 && verifiedFiles == 0
                    ? "已完成个人目录切换（源个人目录共 0 个文件；原盘根层或「图库 / PhonePhotos」中的既有文件仍保留在原盘）。"
                    : "已复制 \(filesSummary) 并完成切换，旧盘原件保留。"
            default:
                suffix = totalF == 0 && verifiedFiles == 0
                    ? "已完成个人目录切换（源个人目录共 0 个文件；原盘根层或「图库 / PhonePhotos」中的既有文件仍保留在原盘）。"
                    : "已切换 \(filesSummary)，源盘 \(deletedSourceFiles) 个文件已移入回收站。"
            }
            return StorageSwitchStagePresentation(
                stepIndex: 5,
                totalSteps: 5,
                title: "第 5/5 步 · 换盘已完成",
                subtitle: suffix,
                fraction: 1.0
            )
        case "source_pending":
            return StorageSwitchStagePresentation(
                stepIndex: 4,
                totalSteps: 5,
                title: "空间已切换 · 源盘清理待恢复",
                subtitle: "新硬盘已生效，但源盘移入回收站未完成，请点击「恢复源盘清理」。",
                fraction: 1.0
            )
        case "interrupted":
            return StorageSwitchStagePresentation(
                stepIndex: 2,
                totalSteps: 5,
                title: "任务中断 · 等待管理员处理",
                subtitle: "切换尚未全部完成，请接回两块硬盘后继续或取消。",
                fraction: fraction
            )
        case "cancelled":
            return StorageSwitchStagePresentation(
                stepIndex: 1,
                totalSteps: 5,
                title: "任务已取消",
                subtitle: "临时暂存目录已清理，源盘数据与绑定保持不变。",
                fraction: nil
            )
        default:
            return StorageSwitchStagePresentation(
                stepIndex: 1,
                totalSteps: 5,
                title: "任务未完成",
                subtitle: "请查看下方提示信息并核对硬盘状态。",
                fraction: fraction
            )
        }
    }

    static func mediaAndShareImpactNote(for mode: String) -> String {
        let scopeNote = "• 迁移目录范围：仅复制或切换个人专属目录（Users/u<id>/files、photos、videos）；若旧盘根层、「图库」或「PhonePhotos」中存有早期照片或文件，不会自动搬移，原件与相册仍完整保留在旧盘。\n"
        switch mode {
        case "empty":
            return scopeNote + "• 照片收藏、私密相册与影院观看进度：空白启用模式不复制旧盘文件，旧盘的收藏/私密相册/播放进度仍留在旧盘，新盘将从空白记录开始。\n• 共享相册与公开分享链接：绑定在旧盘路径上的共享相册及公开分享链接将在切换后自动失效，切换完成后需在新盘重新分享。"
        default:
            return scopeNote + "• 照片收藏、私密相册与影院观看进度：通过 SHA-256 校验的本人照片收藏、私密相册及影院观看进度会自动迁移到新盘。\n• 共享相册与公开分享链接：绑定在旧盘路径上的共享相册及公开分享链接仍归属旧盘，切换完成后可在新盘重新创建。"
        }
    }
}
