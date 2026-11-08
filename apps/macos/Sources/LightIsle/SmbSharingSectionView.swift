import AppKit
import SwiftUI

struct SmbSharingSectionView: View {
    @ObservedObject var model: AppModel
    var showNotice: (String) -> Void

    @State private var selectedRootID = ""
    @State private var selectedSubpath = ""
    @State private var customSMBName = ""
    @State private var newShareReadOnly = false
    @State private var newShareGuest = false
    @State private var newShareSealed = false

    private var onlineRoots: [NativeSMBCandidateRoot] {
        (model.smbState?.candidateRoots ?? []).filter(\.online)
    }

    private var selectedRoot: NativeSMBCandidateRoot? {
        onlineRoots.first { $0.rootId == selectedRootID } ?? onlineRoots.first
    }

    private var selectionExposesPersonalDirs: Bool {
        guard selectedRoot != nil else { return false }
        let sub = selectedSubpath.trimmingCharacters(in: .whitespacesAndNewlines)
        return sub.isEmpty || sub == "Users" || sub.hasPrefix("Users/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            serviceAndAuthorizationSection
            sharesListSection
            addShareSection
        }
        .onAppear {
            model.refreshSMBState()
            syncDefaultRootSelection()
        }
        .onChange(of: model.smbState?.candidateRoots) { _, _ in
            syncDefaultRootSelection()
        }
    }

    private func syncDefaultRootSelection() {
        if selectedRootID.isEmpty || !onlineRoots.contains(where: { $0.rootId == selectedRootID }) {
            selectedRootID = onlineRoots.first?.rootId ?? ""
            selectedSubpath = ""
        }
    }

    private var serviceAndAuthorizationSection: some View {
        AppleSettingsGroup(
            title: "macOS 系统文件共享 (SMB)",
            footer: "开启后 macOS 自动通过 Bonjour (_smb._tcp) 与 NetBIOS 在局域网广播，访达「网络」、Windows、手机「文件」App 及 Infuse/VLC 可直接搜索到本机。这里使用 Mac 系统账号或访客登录；首次使用某 Mac 账号密码连接 SMB 时，需在「系统共享设置 → Windows 文件共享」中勾选该账号。"
        ) {
            AppleSettingsRow(
                title: "SMB 文件共享服务",
                subtitle: model.smbState?.computerName.isEmpty == false ? "局域网显示名称：\(model.smbState?.computerName ?? "")" : "由 macOS smbd 提供局域网文件共享",
                icon: "externaldrive.connected.to.line.below",
                iconTint: .orange
            ) {
                HStack(spacing: 10) {
                    if model.smbBusy {
                        ProgressView().controlSize(.small)
                    }
                    let enabled = model.smbState?.serviceEnabled ?? (model.smbListening == true)
                    Text(enabled ? "已开启" : "未开启")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(enabled ? .green : .secondary)
                    Toggle("启用 SMB 文件共享", isOn: Binding(
                        get: { enabled },
                        set: { model.setSMBServiceEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(model.state != .online || model.smbBusy || model.smbState?.remoteManageReady != true)
                    Button("刷新") { model.refreshSMBState() }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(model.state != .online || model.smbBusy)
                }
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(
                title: "三端免密管理授权",
                subtitle: model.smbState?.remoteManageReady == true
                    ? "已就绪（/etc/sudoers.d/lightisle-smb）：Mac、Web 和手机客户端管理员均可直接控制 SMB。"
                    : "开启后，Mac、Web 和手机客户端管理员可直接开关 SMB 与管理共享文件夹，无需每次弹窗输入密码。",
                icon: "checkmark.shield",
                iconTint: model.smbState?.remoteManageReady == true ? .green : .indigo
            ) {
                HStack(spacing: 8) {
                    if model.smbState?.remoteManageReady == true {
                        Button("撤销授权…") { model.revokeSMBSudoersAuthorization() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.smbBusy)
                    } else {
                        Button("开启免密管理授权…") { model.installSMBSudoersAuthorization() }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                            .disabled(model.smbBusy)
                    }
                    Button("系统共享设置…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
            }
            if let bonjour = model.smbState?.bonjourUrl, !bonjour.isEmpty {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "局域网主机地址", subtitle: "支持 Bonjour 的 Mac、iOS 与播放器可直接使用", icon: "network", iconTint: .blue) {
                    addressToolbar(url: bonjour)
                }
            }
            if let lan = model.smbState?.lanUrl, !lan.isEmpty {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "局域网 IP 地址", subtitle: "适用于 Windows 资源管理器或直接按 IP 挂载", icon: "wifi", iconTint: .cyan) {
                    addressToolbar(url: lan)
                }
            }
            if let err = model.smbError {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "操作提示", icon: "exclamationmark.triangle.fill", iconTint: .red) {
                    Text(err).font(.caption).foregroundStyle(IsleTheme.errorText).textSelection(.enabled)
                }
            }
            if let notice = model.smbNotice {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "状态更新", icon: "checkmark.circle.fill", iconTint: .green) {
                    Text(notice).font(.caption).foregroundStyle(.green)
                }
            }
        }
    }

    private func addressToolbar(url: String) -> some View {
        HStack(spacing: 8) {
            Text(url)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(IsleTheme.accent)
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                showNotice("已复制 \(url)")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
            .help("复制 SMB 地址")
        }
    }

    private var sharesListSection: some View {
        let shares = model.smbState?.shares ?? []
        return AppleSettingsGroup(
            title: "当前已共享文件夹 (\(shares.count))",
            footer: "移除共享只会从 macOS 文件共享列表中取消登记，绝不会删除硬盘上的任何原始文件。"
        ) {
            if shares.isEmpty {
                AppleSettingsRow(
                    title: "暂无 SMB 共享文件夹",
                    subtitle: "可在下方选择 NAS 存储目录或本机文件夹添加到局域网共享。",
                    icon: "folder.badge.questionmark",
                    iconTint: .secondary
                ) { EmptyView() }
            } else {
                ForEach(Array(shares.enumerated()), id: \.element.id) { idx, share in
                    if idx > 0 {
                        IsleGroupSpacing(height: 4).padding(.leading, 14)
                    }
                    shareRow(share)
                }
            }
        }
    }

    private func shareRow(_ share: NativeSMBSharePoint) -> some View {
        let canEdit = model.state == .online && !model.smbBusy && model.smbState?.remoteManageReady == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: share.shared ? "folder.fill.badge.person.crop" : "folder.badge.minus")
                    .foregroundStyle(share.shared ? .blue : .secondary)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(share.smbName).font(.system(size: 13, weight: .semibold))
                        if let rootName = share.rootName, !rootName.isEmpty {
                            Text("NAS · \(rootName)")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(IsleTheme.accent.opacity(0.14))
                                .clipShape(Capsule())
                        }
                        if !share.pathExists {
                            Text("路径离线或不存在")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(IsleTheme.warningText)
                        }
                    }
                    Text(share.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .textSelection(.enabled)
                    if share.exposesPersonalDirs {
                        Label("包含 Users 私人目录：SMB 使用 Mac 账号/访客权限，不受轻屿成员隔离与配额账本限制。", systemImage: "exclamationmark.shield.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(IsleTheme.warningText)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: share.path)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                    .help("在访达中查看")

                    Button("移除") {
                        model.removeSMBShare(share)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(!canEdit)
                }
            }
            HStack(spacing: 14) {
                Toggle("启用共享", isOn: Binding(
                    get: { share.shared },
                    set: { model.updateSMBShare(share, shared: $0) }
                ))
                Toggle("仅只读", isOn: Binding(
                    get: { share.readOnly },
                    set: { model.updateSMBShare(share, readOnly: $0) }
                ))
                Toggle("允许访客", isOn: Binding(
                    get: { share.guestAccess },
                    set: { model.updateSMBShare(share, guestAccess: $0) }
                ))
                Toggle("SMB3 加密", isOn: Binding(
                    get: { share.sealed },
                    set: { model.updateSMBShare(share, sealed: $0) }
                ))
                Spacer()
            }
            .font(.system(size: 11))
            .toggleStyle(.checkbox)
            .disabled(!canEdit)
            .padding(.leading, 26)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var addShareSection: some View {
        let canAdd = model.state == .online && !model.smbBusy && model.smbState?.remoteManageReady == true
        return AppleSettingsGroup(
            title: "添加 SMB 共享文件夹",
            footer: "优先选择公开媒体或家庭共享子目录；内部 .lightisle-* 元数据目录受系统安全保护不可共享。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if onlineRoots.isEmpty {
                    Text("当前没有在线的已登记 NAS 存储目录，也可直接选择本机其他文件夹。")
                        .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                } else {
                    HStack(spacing: 12) {
                        Picker("NAS 存储盘", selection: $selectedRootID) {
                            ForEach(onlineRoots) { root in
                                Text(root.name).tag(root.rootId)
                            }
                        }
                        .onChange(of: selectedRootID) { _, _ in selectedSubpath = "" }

                        Picker("共享范围", selection: $selectedSubpath) {
                            Text("整块存储根目录").tag("")
                            if let root = selectedRoot {
                                ForEach(root.subdirectories, id: \.self) { sub in
                                    Text("子目录：\(sub)").tag(sub)
                                }
                            }
                        }
                    }
                    .disabled(!canAdd)
                    if selectionExposesPersonalDirs {
                        Label("注意：共享整块存储根或 Users 目录会使局域网 SMB 用户直接访问成员私人目录，且写入不计入轻屿配额账本。", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.warningText)
                    }
                }
                HStack(spacing: 12) {
                    TextField("自定义共享名称（留空则使用文件夹名）", text: $customSMBName)
                        .textFieldStyle(.roundedBorder)
                    Toggle("仅只读", isOn: $newShareReadOnly).toggleStyle(.checkbox)
                    Toggle("允许访客", isOn: $newShareGuest).toggleStyle(.checkbox)
                    Toggle("SMB3 加密", isOn: $newShareSealed).toggleStyle(.checkbox)
                }
                .font(.system(size: 12))
                .disabled(!canAdd)

                HStack(spacing: 10) {
                    if let root = selectedRoot {
                        Button("添加所选 NAS 目录") {
                            model.addSMBShare(
                                rootID: root.rootId,
                                subpath: selectedSubpath,
                                smbName: customSMBName,
                                guestAccess: newShareGuest,
                                readOnly: newShareReadOnly,
                                sealed: newShareSealed
                            )
                            customSMBName = ""
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(!canAdd)
                    }
                    Button("选择其他本机文件夹…") {
                        model.selectCustomFolderForSMBShare(
                            smbName: customSMBName,
                            guestAccess: newShareGuest,
                            readOnly: newShareReadOnly,
                            sealed: newShareSealed
                        )
                        customSMBName = ""
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(!canAdd)
                    Spacer()
                }
            }
            .padding(14)
        }
    }
}
