import SwiftUI

struct CreateMemberSpaceSheet: View {
    private enum CreationFlowState: Equatable {
        case editing
        case creatingAccount
        case accountCreatedPendingAllocation(NativeSpaceUserAccount)
        case retryingAllocation(NativeSpaceUserAccount)

        var createdAccount: NativeSpaceUserAccount? {
            switch self {
            case .accountCreatedPendingAllocation(let user), .retryingAllocation(let user):
                return user
            case .editing, .creatingAccount:
                return nil
            }
        }

        var isSubmitting: Bool {
            switch self {
            case .creatingAccount, .retryingAllocation:
                return true
            case .editing, .accountCreatedPendingAllocation:
                return false
            }
        }
    }

    @ObservedObject var spaces: NativeSpacesModel
    var onNavigateToStorage: (() -> Void)? = nil
    var onAddExternalRoot: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private enum CreateField: Hashable { case username, password }
    @FocusState private var focusedField: CreateField?
    @State private var flowState: CreationFlowState = .editing
    @State private var username = ""
    @State private var password = ""
    @State private var selectedRootID = ""
    @State private var quotaGiB = "100"
    @State private var bindFiles = true
    @State private var bindPhotos = true
    @State private var bindVideos = true
    @State private var subdirectories = ""

    private var usernameValidation: FieldValidationStatus {
        AccountInputValidator.validateUsername(username)
    }

    private var passwordValidation: FieldValidationStatus {
        AccountInputValidator.validatePassword(password)
    }

    private var quotaValidation: QuotaValidationResult {
        QuotaInputValidator.validateGiB(quotaGiB)
    }

    private var selectedRoot: NativeSpaceRootInfo? {
        spaces.onlineRoots.first(where: { $0.rootID == selectedRootID }) ?? spaces.onlineRoots.first
    }

    private var selectedCategories: [String] {
        var result: [String] = []
        if bindFiles { result.append("files") }
        if bindPhotos { result.append("photos") }
        if bindVideos { result.append("videos") }
        return result
    }

    private var parsedSubdirectories: [String] {
        subdirectories
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var canSubmitInitialCreate: Bool {
        guard usernameValidation.isValid, passwordValidation.isValid else { return false }
        if !spaces.onlineRoots.isEmpty {
            return quotaValidation.isValid
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusBannerSection
                    credentialsSection
                    storageAllocationSection
                }
                .padding(.vertical, 2)
            }
            Divider()
            footerActions
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 560, maxWidth: 600, minHeight: 420, idealHeight: 490, maxHeight: 550)
        .onAppear {
            spaces.clearLastOperationState()
            selectedRootID = spaces.onlineRoots.first(where: \.isDefault)?.rootID
                ?? spaces.onlineRoots.first?.rootID
                ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                focusedField = .username
            }
        }
        .onChange(of: spaces.busy) { _, isBusy in
            guard !isBusy, flowState.isSubmitting else { return }
            handleSubmissionFinished()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(flowState.createdAccount == nil ? "新建家庭成员并分配存储空间" : "为已创建成员完成存储空间分配")
                .font(.system(size: 16, weight: .semibold))
            Text("账号与权限配置固定保存在 Mac 系统盘；成员的个人文件、相册与影视目录存放在所选的存储硬盘上。")
                .font(.caption)
                .foregroundStyle(IsleTheme.secondaryText)
        }
    }

    @ViewBuilder
    private var statusBannerSection: some View {
        if flowState.isSubmitting {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(
                    flowState == .creatingAccount
                        ? (spaces.onlineRoots.isEmpty ? "正在创建成员账号…" : "第 1/2 步：正在创建账号并初始化存储目录…")
                        : "第 2/2 步：正在为已创建账号重试分配存储目录与配额…"
                )
                .font(.caption)
                .foregroundStyle(IsleTheme.secondaryText)
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(IsleTheme.accent.opacity(0.1)))
        }

        if let created = flowState.createdAccount {
            VStack(alignment: .leading, spacing: 4) {
                Label("第 1/2 步已完成：成员账号「\(created.username)」已创建", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.green)
                Text("无需重复创建账号。请检查下方存储硬盘或配额设置后点击「仅重试空间分配」，或先关闭窗口稍后在页面下方分配。")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.secondaryText)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.1)))
        }

        if let err = spaces.errorMessage {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(IsleTheme.warningText)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        }
    }

    private var credentialsSection: some View {
        let locked = flowState.createdAccount != nil || flowState.isSubmitting
        return VStack(alignment: .leading, spacing: 10) {
            Text("1. 账号凭据").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                TextField("用户名（3–32 位字母 / 数字 / . _ -）", text: $username)
                    .liquidInput()
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
                    .disabled(locked)
                if let msg = usernameValidation.message {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(usernameValidation.isValid ? IsleTheme.secondaryText : IsleTheme.warningText)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                LiquidSecureField(prompt: "登录密码（至少 12 位）", text: $password)
                    .focused($focusedField, equals: .password)
                    .disabled(locked)
                if let msg = passwordValidation.message {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(passwordValidation.isValid ? IsleTheme.secondaryText : IsleTheme.warningText)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
    }

    private var storageAllocationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2. 初始存储空间分配").font(.system(size: 13, weight: .semibold))
            if spaces.onlineRoots.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "当前没有在线的存储硬盘。你可以先仅创建成员账号，待接入或添加硬盘后再为其分配文件、相册和影视目录。",
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(IsleTheme.warningText)
                    if let onNavigateToStorage {
                        Button("前往「存储位置」添加或连接硬盘…") {
                            dismiss()
                            onNavigateToStorage()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            } else {
                HStack(spacing: 8) {
                    Picker("存放硬盘", selection: $selectedRootID) {
                        ForEach(spaces.onlineRoots) { r in
                            Text("\(r.name)\(r.isDefault ? " · 主存储" : "")（\(r.path)）").tag(r.rootID)
                        }
                    }
                    .disabled(flowState.isSubmitting)
                    if let onAddExternalRoot {
                        Button("+ 选择外置硬盘…") {
                            onAddExternalRoot()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(flowState.isSubmitting)
                    }
                }
                .onChange(of: spaces.roots) { oldRoots, newRoots in
                    let oldIDs = Set(oldRoots.map(\.rootID))
                    if let added = newRoots.first(where: { $0.online && !oldIDs.contains($0.rootID) }) {
                        selectedRootID = added.rootID
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("该盘配额上限 (GiB)：")
                            .font(.caption)
                            .fixedSize(horizontal: true, vertical: false)
                        ForEach([50, 100, 200, 500, 1024], id: \.self) { preset in
                            Button(preset >= 1024 ? "1 TB" : "\(preset) GB") {
                                quotaGiB = "\(preset)"
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(flowState.isSubmitting)
                        }
                        Spacer(minLength: 4)
                        TextField("100", text: $quotaGiB)
                            .liquidInput()
                            .frame(width: 78)
                            .disabled(flowState.isSubmitting)
                    }
                    if let err = quotaValidation.errorMessage {
                        Text(err).font(.caption2).foregroundStyle(IsleTheme.warningText)
                    } else {
                        Text("点击快捷按钮仅填入数值；留空或输入 0 表示不限制软件配额。")
                            .font(.caption2)
                            .foregroundStyle(IsleTheme.secondaryText)
                    }
                }

                HStack(spacing: 14) {
                    Toggle(SpaceCategoryPresentation.detailLabel(for: "files"), isOn: $bindFiles)
                        .toggleStyle(.checkbox)
                    Toggle(SpaceCategoryPresentation.detailLabel(for: "photos"), isOn: $bindPhotos)
                        .toggleStyle(.checkbox)
                    Toggle(SpaceCategoryPresentation.detailLabel(for: "videos"), isOn: $bindVideos)
                        .toggleStyle(.checkbox)
                }
                .disabled(flowState.isSubmitting)

                TextField("初始子目录（可选，逗号分隔，如 files/文档, photos/旅行）", text: $subdirectories)
                    .liquidInput()
                    .disabled(flowState.isSubmitting)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
    }

    private var footerActions: some View {
        HStack {
            Spacer()
            if let created = flowState.createdAccount {
                Button("稍后在详情页配置（关闭）") {
                    spaces.selectedUserID = created.id
                    dismiss()
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary))
                .keyboardShortcut(.cancelAction)
                .disabled(flowState.isSubmitting)

                Button("仅重试空间分配") {
                    guard let root = selectedRoot, quotaValidation.isValid else { return }
                    flowState = .retryingAllocation(created)
                    spaces.allocateSpace(
                        userID: created.id,
                        rootID: root.rootID,
                        generation: root.generation,
                        quotaBytes: quotaValidation.quotaBytes,
                        categories: selectedCategories,
                        subdirectories: parsedSubdirectories
                    )
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent))
                .keyboardShortcut(.defaultAction)
                .disabled(flowState.isSubmitting || selectedRoot == nil || !quotaValidation.isValid || (selectedCategories.isEmpty && parsedSubdirectories.isEmpty))
            } else {
                Button("取消") { dismiss() }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary))
                    .keyboardShortcut(.cancelAction)
                    .disabled(flowState.isSubmitting)

                Button(spaces.onlineRoots.isEmpty ? "仅创建成员账号" : "创建成员并分配空间") {
                    guard canSubmitInitialCreate else { return }
                    flowState = .creatingAccount
                    let root = selectedRoot
                    spaces.createUser(
                        username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                        password: password,
                        rootID: root?.rootID,
                        generation: root?.generation,
                        quotaBytes: root != nil ? quotaValidation.quotaBytes : nil,
                        categories: root != nil ? selectedCategories : [],
                        subdirectories: root != nil ? parsedSubdirectories : []
                    )
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent))
                .keyboardShortcut(.defaultAction)
                .disabled(flowState.isSubmitting || !canSubmitInitialCreate)
            }
        }
    }

    private func handleSubmissionFinished() {
        if spaces.errorMessage == nil {
            dismiss()
            return
        }
        if let created = spaces.lastCreatedUser ?? flowState.createdAccount {
            flowState = .accountCreatedPendingAllocation(created)
        } else {
            flowState = .editing
        }
    }
}
