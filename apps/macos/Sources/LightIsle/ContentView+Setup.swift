import SwiftUI
import AppKit

extension ContentView {
    var connectionStatusTitle: String {
        if case .error = model.state { return "暂时无法连接轻屿" }
        return "正在连接本机服务"
    }
    var connectionStatusMessage: String {
        if case .error(let message) = model.state { return message }
        return model.details
    }
    var connectingView: some View {
        ZStack {
            IsleBackdrop()
            VStack(spacing: 24) {
                if model.isPresentationPreview { Text("设计预览 · 模拟数据").font(.system(size: 12)).foregroundStyle(IsleTheme.secondaryText) }
                VStack(spacing: 18) {
                    BrandMark(size: 72)
                    if case .error = model.state { EmptyView() }
                    else { ProgressView().controlSize(.small) }
                }

                VStack(spacing: 6) {
                    Text(connectionStatusTitle)
                        .font(.title3.weight(.bold))
                    Text(connectionStatusMessage)
                        .font(.subheadline)
                        .foregroundStyle(IsleTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                if case .error = model.state {
                    Text(model.details)
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                        .multilineTextAlignment(.center)
                    if let port = model.corePortConflict {
                        CorePortRecoveryView(port: port).id(port)
                    } else {
                        Button("重新启动轻屿服务") { model.launch() }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                        Button("修复上次中断的数据库恢复…") { model.recoverInterruptedMetadata() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .regular))
                            .disabled(model.isPresentationPreview || model.activatingMetadata)
                        Button("查看可回退的数据库版本…") {
                            showingRollbackRecovery = true
                            model.refreshMetadataRollbacks()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .regular))
                        .disabled(model.isPresentationPreview || model.activatingMetadata)
                    }
                }
                if let message = model.metadataActivationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 500)
                }
            }
            .padding(40)
        }
    }

    // MARK: - Native Setup (First Run)
    var nativeSetupView: some View {
        ZStack {
            IsleBackdrop()

            ScrollView {
                VStack(spacing: 20) {
                    if model.isPresentationPreview { Text("设计预览 · 模拟数据").font(.system(size: 12)).foregroundStyle(IsleTheme.secondaryText) }
                    VStack(spacing: 12) {
                        BrandMark(size: 70)


                        Text("创建首任管理员")
                            .font(.system(size: 24, weight: .bold))
                        Text("轻屿管理本机服务和已授权的共享目录，不提供公网注册。请在当前设备上创建首位管理员账号。")
                            .font(.system(size: 13))
                            .foregroundStyle(IsleTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }

                    AppleSettingsGroup {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Label("共享数据目录", systemImage: "externaldrive.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                    Spacer()
                                    Button("使用 ~/LightIsle（推荐）") {
                                        model.selectPresetSharedFolder(path: homeVisibleSharedFolderPath, name: "LightIsle")
                                    }
                                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    .disabled(model.isPresentationPreview || model.state != .online || model.rootManagement.busy)
                                    Button("自定义目录…") {
                                        model.selectSharedFolder()
                                    }
                                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    .disabled(model.isPresentationPreview || model.state != .online || model.rootManagement.busy)
                                }

                                Text("默认或已选存储位置")
                                    .font(.caption)
                                    .foregroundStyle(IsleTheme.secondaryText)
                                Text(model.sharedFolderPath ?? defaultSharedFolderPath)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)

                                if let currentPath = model.sharedFolderPath {
                                    Text(currentPath == defaultSharedFolderPath
                                         ? "当前正在使用系统 Application Support 默认目录（可一键切换至访达可见的 ~/LightIsle 或外置硬盘）"
                                         : "当前共享目录：\(currentPath)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(IsleTheme.secondaryText)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let error = model.sharedFolderError {
                                    Text("当前目录不可用：\(error)")
                                        .font(.caption)
                                        .foregroundStyle(IsleTheme.warningText)
                                }
                                Text("可现在选择容量足够的内部或外置磁盘，也可之后在“数据与存储”中更改。只有确认选择后才会更改共享目录；现有文件不会自动迁移，也不会更改管理员账号。")
                                    .font(.caption)
                                    .foregroundStyle(IsleTheme.secondaryText)
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            IsleGroupSpacing(height: 4)

                            VStack(alignment: .leading, spacing: 5) {
                                Text("管理员账号")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(IsleTheme.secondaryText)
                                TextField("3–32 位英文字母、数字或 . _ -", text: $firstUsername)
                                    .liquidInput()
                            }

                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("登录密码")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(IsleTheme.secondaryText)
                                    Spacer()
                                    if !firstPassword.isEmpty {
                                        Text(firstPassword.count >= 12 ? "长度合规" : "至少需 12 位（当前 \(firstPassword.count)）")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(firstPassword.count >= 12 ? .green : .orange)
                                    }
                                }
                                SecureField("至少 12 位密码", text: $firstPassword)
                                    .liquidInput()
                            }

                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("确认密码")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(IsleTheme.secondaryText)
                                    Spacer()
                                    if !confirmPassword.isEmpty {
                                        if firstPassword == confirmPassword {
                                            Text("密码一致")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(IsleTheme.successText)
                                        } else {
                                            Text("两次密码不一致")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(IsleTheme.errorText)
                                        }
                                    }
                                }
                                SecureField("请再次输入相同密码", text: $confirmPassword)
                                    .liquidInput()
                            }

                            if let error = model.initializationError {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                    Text(error)
                                        .font(.caption)
                                }
                                .foregroundStyle(IsleTheme.errorText)
                            }

                            Button {
                                model.initializeAdministrator(username: firstUsername, password: firstPassword)

                            } label: {
                                HStack(spacing: 8) {
                                    if model.initializing {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text(model.initializing ? "正在创建管理员…" : "创建管理员并进入轻屿")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .large))
                            .disabled(model.isPresentationPreview || !isFormValid || model.initializing || model.state != .online)
                        }
                        .padding(18)
                    }
                    .frame(width: 420)

                    Button {
                        showingManualIntro = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.circle")
                            Text("重新播放开场动画")
                        }
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
    }

    var isFormValid: Bool {
        !firstUsername.isEmpty &&
        firstPassword.count >= 12 &&
        firstPassword == confirmPassword
    }

    var defaultSharedFolderPath: String {
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return supportURL
            .appendingPathComponent("LightIsle", isDirectory: true)
            .appendingPathComponent("SharedFiles", isDirectory: true)
            .path
    }

    var homeVisibleSharedFolderPath: String {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("LightIsle", isDirectory: true)
            .path
    }

}
