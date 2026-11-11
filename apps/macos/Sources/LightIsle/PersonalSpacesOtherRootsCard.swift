import AppKit
import SwiftUI

struct PersonalSpacesTransferBanner: View {
    @ObservedObject var spaces: NativeSpacesModel
    let entry: NativeSpaceUserEntry
    let transfer: NativeStorageSwitchResult
    let onOpenSheet: (String, UInt64, Set<String>) -> Void

    var body: some View {
        let stage = StorageSwitchStagePresentation.describe(
            phase: transfer.phase,
            mode: transfer.mode,
            copiedBytes: transfer.copiedBytes,
            totalBytes: transfer.totalBytes,
            verifiedFiles: transfer.verifiedFiles,
            totalFiles: transfer.totalFiles,
            deletedSourceFiles: transfer.deletedSourceFiles
        )
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: transfer.phase == "verified" ? "checkmark.shield.fill" : "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(transfer.phase == "verified" ? .green : IsleTheme.warningText)
                Text("当前换盘任务：\(stage.title)")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if let primaryLoc = entry.policy.locations.first {
                    Button("打开换盘任务处理…") {
                        onOpenSheet(
                            primaryLoc.rootID,
                            primaryLoc.rootGeneration,
                            Set(entry.policy.locations.filter { $0.rootID == primaryLoc.rootID }.map(\.category))
                        )
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                }
                if transfer.phase == "verified" || (transfer.phase == "interrupted" && transfer.canCancel == true) {
                    Button("取消任务") {
                        spaces.readStorageSwitch(userID: entry.user.id, taskID: transfer.taskID, phase: "cancel")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(spaces.busy)
                }
            }
            Text(stage.subtitle)
                .font(.caption)
                .foregroundStyle(IsleTheme.secondaryText)
            if let errCode = transfer.error, !errCode.isEmpty {
                Text(spaces.humanizeSpacesError(errCode, detail: transfer.errorDetail, reviewPath: transfer.reviewPath))
                    .font(.caption)
                    .foregroundStyle(IsleTheme.warningText)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.1)))
    }
}

struct PersonalSpacesOtherRootsNotice: View {
    let userID: Int64
    let boundRootIDs: Set<String>
    let allRoots: [NativeSpaceRootInfo]

    private var otherRoots: [NativeSpaceRootInfo] {
        let unbound = allRoots.filter { !boundRootIDs.contains($0.rootID) }
        return unbound.isEmpty ? (allRoots.count > 1 ? allRoots : []) : unbound
    }

    var body: some View {
        if !otherRoots.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("找不到迁移前的相册或文件？查看其他已登记存储目录（原数据未删除）", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(IsleTheme.accent)
                Text("个人空间换盘仅迁移 Users/u\(userID)/ 下的专属分类目录。若此前照片或文件保存在原目录根层、「图库」或「PhonePhotos」中，原件与相册均完整保留在下方原目录内：可在 Web/App 顶部硬盘切换器切回原目录查看，或点击「在访达中打开」将照片拖入新盘 Users/u\(userID)/photos 后重新扫描媒体。")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(otherRoots) { root in
                    HStack(spacing: 8) {
                        IsleStatusPill(
                            text: "\(root.name)\(root.isDefault ? " · 默认主存储" : "") · \(root.online ? "在线" : "离线")",
                            tone: root.online ? .accent : .warning,
                            showDot: true
                        )
                        Text(root.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(IsleTheme.secondaryText)
                            .textSelection(.enabled)
                        Spacer()
                        if FileManager.default.fileExists(atPath: root.path) {
                            Button("在访达中打开原目录") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: root.path))
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                    }
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IsleTheme.accent.opacity(0.07)))
        }
    }
}

struct PersonalSpacesMemberSecurityCard: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var spaces: NativeSpacesModel
    let entry: NativeSpaceUserEntry
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    private var validNewPassword: Bool {
        newPassword.utf8.count >= 12
            && newPassword.trimmingCharacters(in: .whitespacesAndNewlines) == newPassword
            && newPassword == confirmPassword
    }

    var body: some View {
        AppleSettingsGroup(
            title: "\(entry.user.username) · 账号状态与密码管理",
            footer: "停用成员账号或重置密码后，该成员原有的 Web 与客户端登录会话将立即失效；共享文件夹与电脑文件访问权限可在 Web 管理端「设置 → 账号与安全」中按需配置。"
        ) {
            AppleSettingsRow(
                title: "登录权限状态",
                subtitle: entry.user.enabled ? "当前允许该成员登录并使用已分配的个人空间与授权目录。" : "账号已停用，无法登录或访问共享文件（原有个人空间文件安全保留）。",
                icon: entry.user.enabled ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark",
                iconTint: entry.user.enabled ? .green : .orange
            ) {
                HStack(spacing: 8) {
                    IsleStatusPill(
                        text: entry.user.enabled ? "已启用" : "已停用",
                        tone: entry.user.enabled ? .success : .warning,
                        showDot: true
                    )
                    Button(entry.user.enabled ? "停用账号" : "启用账号") {
                        spaces.setUserEnabled(userID: entry.user.id, enabled: !entry.user.enabled)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: entry.user.enabled ? .destructive : .prominent, size: .small))
                    .disabled(!spaces.connected || spaces.busy)
                    Button("目录与电脑文件授权 ↗") {
                        appModel.openUserWeb(page: "settings")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
            }
            if entry.user.enabled {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(
                    title: "重置成员密码",
                    subtitle: "至少 12 位且首尾不含空格；重置后该成员需使用新密码重新登录。",
                    icon: "key.horizontal.fill",
                    iconTint: .indigo
                ) {
                    HStack(spacing: 8) {
                        SecureField("新密码（至少 12 位）", text: $newPassword)
                            .liquidInput()
                            .frame(width: 150)
                        SecureField("确认新密码", text: $confirmPassword)
                            .liquidInput()
                            .frame(width: 150)
                        Button("重置密码") {
                            let pwd = newPassword
                            newPassword = ""
                            confirmPassword = ""
                            spaces.resetUserPassword(userID: entry.user.id, newPassword: pwd)
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(!spaces.connected || spaces.busy || !validNewPassword)
                    }
                }
            }
        }
    }
}
