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
        NativeFirstRunSetupContent(
            model: model,
            firstUsername: $firstUsername,
            firstPassword: $firstPassword,
            confirmPassword: $confirmPassword,
            showingManualIntro: $showingManualIntro,
            showAdvancedStorage: $showSetupAdvancedStorage,
            probeCache: $setupStorageProbeCache,
            defaultPath: defaultSharedFolderPath,
            homeVisiblePath: homeVisibleSharedFolderPath
        )
    }

    var cachedSetupStorageProbe: StoragePermissionHelper.AccessProbeResult {
        if model.isPresentationPreview { return .writable }
        return setupStorageProbeCache ?? .writable
    }

    var isFormValid: Bool {
        cachedSetupStorageProbe.isWritable &&
        AccountInputValidator.validateUsername(firstUsername).isValid &&
        AccountInputValidator.validatePassword(firstPassword).isValid &&
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

private struct NativeFirstRunSetupContent: View {
    private enum SetupField: Hashable { case username, password, confirm }

    @ObservedObject var model: AppModel
    @Binding var firstUsername: String
    @Binding var firstPassword: String
    @Binding var confirmPassword: String
    @Binding var showingManualIntro: Bool
    @Binding var showAdvancedStorage: Bool
    @Binding var probeCache: StoragePermissionHelper.AccessProbeResult?
    let defaultPath: String
    let homeVisiblePath: String

    @FocusState private var focusedField: SetupField?
    @Environment(\.isleReduceMotion) private var reduceMotion

    private var activePath: String { model.sharedFolderPath ?? defaultPath }
    private var probe: StoragePermissionHelper.AccessProbeResult {
        if model.isPresentationPreview { return .writable }
        return probeCache ?? .writable
    }
    private var isUsingHomeVisible: Bool { activePath == homeVisiblePath }
    private var isUsingCustomExternal: Bool { activePath != homeVisiblePath && activePath != defaultPath }

    private var isFormValid: Bool {
        probe.isWritable &&
        AccountInputValidator.validateUsername(firstUsername).isValid &&
        AccountInputValidator.validatePassword(firstPassword).isValid &&
        firstPassword == confirmPassword
    }

    private var canSubmitNow: Bool {
        !model.isPresentationPreview && isFormValid && !model.initializing && model.state == .online
    }

    var body: some View {
        ZStack {
            IsleBackdrop()
            ScrollView {
                VStack(spacing: 20) {
                    if model.isPresentationPreview {
                        Text("设计预览 · 模拟数据").font(.system(size: 12)).foregroundStyle(IsleTheme.secondaryText)
                    }
                    VStack(spacing: 10) {
                        BrandMark(size: 68)
                        Text("创建首任管理员")
                            .font(.system(size: 24, weight: .bold))
                        Text("轻屿的数据完全保存在这台 Mac 或你指定的外置硬盘上。完成存储位置确认与账号创建即可立即启用。")
                            .font(.system(size: 13))
                            .foregroundStyle(IsleTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }

                    AppleSettingsGroup {
                        VStack(alignment: .leading, spacing: 16) {
                            storageSelectionCard
                            IsleGroupSpacing(height: 2)
                            credentialsFormSection
                        }
                        .padding(18)
                    }
                    .frame(width: 440)

                    Button {
                        showingManualIntro = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.circle")
                            Text("重新播放欢迎介绍")
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
        .onAppear {
            if focusedField == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    focusedField = .username
                }
            }
        }
        .task(id: activePath) {
            await refreshStorageProbe(for: activePath)
        }
    }

    private var storageSelectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("1. 选择文件存放位置", systemImage: "externaldrive.fill.badge.checkmark")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                IsleStatusPill(
                    text: probe.isWritable ? "可读写" : probe.statusSummary,
                    tone: probe.isWritable ? .success : .error,
                    showDot: true
                )
            }

            HStack(spacing: 8) {
                storageChoiceButton(
                    title: "个人目录 LightIsle",
                    subtitle: "推荐 · 在访达直接可见",
                    icon: "folder.fill",
                    selected: isUsingHomeVisible
                ) {
                    model.selectPresetSharedFolder(path: homeVisiblePath, name: "LightIsle")
                }
                storageChoiceButton(
                    title: isUsingCustomExternal ? model.sharedFolderName : "外置硬盘 / 其他目录…",
                    subtitle: isUsingCustomExternal ? "已选外置或自定义目录" : "适合大容量照片与影视",
                    icon: "externaldrive.fill",
                    selected: isUsingCustomExternal
                ) {
                    model.selectSharedFolder()
                }
            }
            .disabled(model.isPresentationPreview || model.state != .online || model.rootManagement.busy)

            DisclosureGroup(isExpanded: $showAdvancedStorage) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前生效路径：\(activePath)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("后续随时可在「数据与存储」中添加更多外置硬盘或迁移成员空间。")
                        .font(.caption2)
                        .foregroundStyle(IsleTheme.secondaryText)
                }
                .padding(.top, 6)
            } label: {
                Text(isUsingHomeVisible ? "已选个人主目录 LightIsle（点击查看路径详情）" : (isUsingCustomExternal ? "已选：\(activePath)" : "当前使用默认存储位置（推荐切换至上方两个直观位置）"))
                    .font(.caption)
                    .foregroundStyle(IsleTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !probe.isWritable {
                VStack(alignment: .leading, spacing: 8) {
                    if let detail = probe.detailMessage {
                        Label(detail, systemImage: "exclamationmark.octagon.fill")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.errorText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("一键获取读写权限") {
                        let path = activePath
                        Task { @MainActor in
                            let access = await StoragePermissionHelper.requestReadWriteAccess(
                                forPath: path,
                                reason: "初始化主存储目录需要持久读写权限，用于创建个人文件、相册与影视空间。",
                                initialProbe: probe
                            )
                            model.sharedFolderError = access.ok ? nil : access.errorMessage
                            await refreshStorageProbe(for: path)
                        }
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                }
            }

            if let error = model.sharedFolderError {
                Label("目录授权提示：\(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func storageChoiceButton(title: String, subtitle: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? IsleTheme.accent : IsleTheme.secondaryText)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(IsleTheme.accent)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(IsleTheme.secondaryText)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? IsleTheme.accent.opacity(0.11) : Color.primary.opacity(0.03))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? IsleTheme.accent : IsleFluidPalette.rim.opacity(0.6), lineWidth: selected ? 1.4 : 0.9)
            }
        }
        .buttonStyle(IslePressStyle())
    }

    private var credentialsFormSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("2. 设置管理员账号与密码", systemImage: "person.badge.key.fill")
                .font(.system(size: 12.5, weight: .semibold))

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("管理员账号")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IsleTheme.secondaryText)
                    Spacer()
                    let usernameStatus = AccountInputValidator.validateUsername(firstUsername)
                    if let msg = usernameStatus.message {
                        Text(msg)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(usernameStatus.isValid ? IsleTheme.successText : (firstUsername.count < 3 ? IsleTheme.secondaryText : IsleTheme.warningText))
                    }
                }
                TextField("例如 admin 或你的名字（3–32 位字母/数字）", text: $firstUsername)
                    .liquidInput()
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("登录密码")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IsleTheme.secondaryText)
                    Spacer()
                    if !firstPassword.isEmpty {
                        let validLen = firstPassword.count >= AccountInputValidator.minPasswordLength
                        let status = AccountInputValidator.validatePassword(firstPassword)
                        Text(status.isValid ? "✓ 长度达标（\(firstPassword.count) 位）" : (validLen ? (status.message ?? "") : "已输入 \(firstPassword.count) / 12 位"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(status.isValid ? IsleTheme.successText : IsleTheme.secondaryText)
                    }
                }
                LiquidSecureField(prompt: "至少 12 位密码（点击右侧眼睛可核对）", text: $firstPassword) {
                    focusedField = .confirm
                }
                .focused($focusedField, equals: .password)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("确认密码")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IsleTheme.secondaryText)
                    Spacer()
                    if !confirmPassword.isEmpty {
                        let matched = firstPassword == confirmPassword
                        Text(matched ? "✓ 两次密码一致" : "两次输入尚未一致")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(matched ? IsleTheme.successText : IsleTheme.warningText)
                    }
                }
                LiquidSecureField(prompt: "再次输入相同密码", text: $confirmPassword) {
                    if canSubmitNow {
                        model.initializeAdministrator(username: firstUsername, password: firstPassword)
                    }
                }
                .focused($focusedField, equals: .confirm)
            }

            if let error = model.initializationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
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
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmitNow)

            if !probe.isWritable {
                Text("请先在上方完成存储目录读写授权后再创建管理员")
                    .font(.caption2)
                    .foregroundStyle(IsleTheme.warningText)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func refreshStorageProbe(for targetPath: String) async {
        if model.isPresentationPreview {
            probeCache = .writable
            return
        }
        let defPath = defaultPath
        let result = await Task.detached(priority: .userInitiated) {
            let targetURL = URL(fileURLWithPath: targetPath, isDirectory: true)
            if !FileManager.default.fileExists(atPath: targetPath), targetPath == defPath {
                try? FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
            }
            return StoragePermissionHelper.probeDirectoryReadWrite(at: targetURL)
        }.value
        withAnimation(reduceMotion ? nil : IsleMotion.quick) {
            probeCache = result
        }
    }
}
