import SwiftUI
import AppKit

// Intentionally lives in the native owner app, not in the remotely reachable
// Web API. Container lifecycle controls can grant effective root inside a VM.
struct DockerManagementView: View {
    @EnvironmentObject var edits: ManagementEdits
    @ObservedObject var appsCenter = AppModel.shared.appsCenter
    @State var mirrorBaseline: [String] = []
    @State var draftTab: DockerDetail?
    @State var showTabConfirmation = false
    var mirrorFields: [String] { [preset, customMirror, String(useCustomMirror), String(applyColima)] }
    var otherInputs: Bool { !imageReference.isEmpty || !importedComposePaths.isEmpty || !newVolumeName.isEmpty || !newNetworkName.isEmpty }
    var dirty: Bool { (!mirrorBaseline.isEmpty && mirrorFields != mirrorBaseline) || otherInputs }
    private var detailBinding: Binding<DockerDetail> {
        Binding(get: { detail }, set: { next in
            if dirty { draftTab = next; showTabConfirmation = true } else { detail = next }
        })
    }
    @Binding var detail: DockerDetail
    @Environment(\.isleReduceMotion) private var reduceMotion
    @Binding var context: String
    @State var snapshot: DockerSnapshot?
    @State var extras: DockerExtras?
    @State var extrasLoading = false
    @State var extrasError: String?
    @State var loading = false
    @State var runningOperation = false
    @State var message: String?
    @State var problem: String?
    @AppStorage("lightisle.docker.mirrorPreset") var preset = "one-ms"
    @AppStorage("lightisle.docker.customMirror") var customMirror = ""
    @AppStorage("lightisle.docker.useCustomMirror") var useCustomMirror = false
    @AppStorage("lightisle.docker.applyColima") var applyColima = false
    @State var mirrorTesting = false
    @State var mirrorTestResult: String?
    @State var imageReference = ""
    @State var showingLogs = false
    @State var logsContainer: DockerContainer?
    @State var logsContent = ""
    @State var logsLoading = false
    @State var logsError: String?
    @State var metricsContainer: DockerContainer?
    @State var containerMetrics: DockerContainerMetrics?
    @State var metricsLoading = false
    @State var metricsError: String?
    @State var showingMetrics = false
    @State var importedComposePaths: [String] = []
    @State var importedComposeName = ""
    @State var newVolumeName = ""
    @State var newNetworkName = ""

    var mirror: String {
        useCustomMirror ? customMirror :
            (DockerMirrorPreset.catalog.first { $0.id == preset }?.url ?? "")
    }
    private var selectedPreset: DockerMirrorPreset? {
        DockerMirrorPreset.catalog.first { $0.id == preset }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LiquidSegmentedPicker(
                title: "应用与容器模式",
                selection: $appsCenter.workspaceSection,
                options: AppsAndContainersSection.allCases.map {
                    LiquidMenuOption(value: $0, label: $0.rawValue, icon: $0.icon)
                },
                style: .tabs
            )
            switch appsCenter.workspaceSection {
            case .plugins:
                AppsPluginCenterView(appsCenter: appsCenter)
            case .mcp:
                MCPDeveloperCenterView(appsCenter: appsCenter)
            case .docker:
                engineSection
                LiquidSegmentedPicker(title: "Docker 资源分类", selection: detailBinding,
                    options: DockerDetail.allCases.map { LiquidMenuOption(value: $0, label: $0.rawValue, icon: $0.icon) }, style: .tabs)
                Group {
                    switch detail {
                    case .containers: containersSection
                    case .compose: composeSection
                    case .images: imagesSection
                    case .resources: resourcesSection
                    case .mirrors: mirrorsSection
                    }
                }
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(IsleTheme.successText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 4)
                }
            }
        }
        .sheet(isPresented: $showingLogs) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("容器日志 · " + (logsContainer?.name ?? ""))
                        .font(.system(size: 16, weight: .bold))
                    Spacer()
                    Button("关闭") { showingLogs = false }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
                if logsLoading {
                    ProgressView("正在读取最近 200 行日志…")
                }
                if let logsError {
                    Text(logsError).font(.caption).foregroundStyle(IsleTheme.errorText)
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(logsContent.isEmpty ? "暂无日志" : logsContent)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                Text("仅显示最近 200 行，上限 1 MiB；日志可能包含敏感信息，请勿直接发送给他人。")
                    .font(.caption).foregroundStyle(IsleTheme.secondaryText)
            }
            .padding(22)
            .frame(minWidth: 680, minHeight: 460)
        }
        .sheet(isPresented: $showingMetrics) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text("容器资源与健康 · " + (metricsContainer?.name ?? ""))
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button("刷新") { if let container = metricsContainer { loadMetrics(for: container) } }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(metricsLoading)
                    Button("关闭") { showingMetrics = false }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
                if metricsLoading { ProgressView("查询本机 Docker…") }
                if let metricsError { Text(metricsError).font(.caption).foregroundStyle(IsleTheme.errorText) }
                if let data = containerMetrics {
                    AppleSettingsGroup(title: "实时采样指标") {
                        AppleSettingsRow(title: "健康状态", icon: "heart.text.square", iconTint: .green) {
                            Text(data.health).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        IsleGroupSpacing(height: 4).padding(.leading, 14)
                        AppleSettingsRow(title: "CPU 占用", icon: "cpu", iconTint: .blue) {
                            Text(data.cpuPercent).font(.system(size: 12, design: .monospaced))
                        }
                        IsleGroupSpacing(height: 4).padding(.leading, 14)
                        AppleSettingsRow(title: "内存使用", icon: "memorychip", iconTint: .purple) {
                            Text(data.memoryUsage + "（" + data.memoryPercent + "）").font(.system(size: 12, design: .monospaced))
                        }
                        IsleGroupSpacing(height: 4).padding(.leading, 14)
                        AppleSettingsRow(title: "网络 I/O", icon: "network", iconTint: .cyan) {
                            Text(data.networkIO).font(.system(size: 12, design: .monospaced))
                        }
                        IsleGroupSpacing(height: 4).padding(.leading, 14)
                        AppleSettingsRow(title: "磁盘 I/O", icon: "internaldrive", iconTint: .orange) {
                            Text(data.diskIO).font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
                Text("仅在你点击时通过本机 Unix Socket 读取一次 docker stats / inspect，不启动常驻监控，不会运行 exec 或更改容器。")
                    .font(.caption).foregroundStyle(IsleTheme.secondaryText)
            }
            .padding(24)
            .frame(minWidth: 520, minHeight: 380)
        }
        .task {
            if AppModel.shared.isPresentationPreview, let value = Bundle.main.object(forInfoDictionaryKey: "LightIsleDesignDocker") as? String, let chosen = DockerDetail(rawValue: value) {
                appsCenter.workspaceSection = .docker
                detail = chosen
            }
            mirrorBaseline = mirrorFields; trackEdits(); if !AppModel.shared.isPresentationPreview { refresh(); appsCenter.refresh() }
        }
        .onChange(of: mirrorFields) { _, _ in trackEdits() }
        .onChange(of: imageReference) { _, _ in trackEdits() }
        .onChange(of: importedComposePaths) { _, _ in trackEdits() }
        .onChange(of: newVolumeName) { _, _ in trackEdits() }
        .onChange(of: newNetworkName) { _, _ in trackEdits() }
        .onChange(of: runningOperation) { _, busy in edits.busy = busy; if !busy { trackEdits() } }
        .onDisappear { edits.reset() }
        .confirmationDialog("此页有尚未保存或执行的输入", isPresented: $showTabConfirmation, titleVisibility: .visible) {
            Button("放弃输入并切换", role: .destructive) { edits.discard?(); if let next = draftTab { detail = next } }
            Button("继续编辑", role: .cancel) { draftTab = nil }
        }
        .animation(reduceMotion ? nil : IsleMotion.navigation, value: detail)
        .onChange(of: detail) { _, next in
            if !AppModel.shared.isPresentationPreview && (next == .images || next == .resources || next == .compose) { refreshExtras(context: context) }
        }
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(title: "Docker 引擎与容器", footer: "仅支持当前 Mac 上安装的 Docker Desktop 或 Colima。不会随 LightIsle 启动虚拟机，也不会在退出时停止第三方容器。") {
                let hasCLI = !AppModel.shared.isPresentationPreview && DockerLocalRuntime.executable() != nil
                AppleSettingsRow(title: "本机 Docker CLI", subtitle: "用于检测并操作当前选中的本地容器上下文", icon: "shippingbox.fill", iconTint: .blue) {
                    StatusBadge(isOnline: hasCLI, text: hasCLI ? "已检测到" : "尚未安装")
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "运行环境", subtitle: "切换后自动重新读取对应引擎的容器与存储快照", icon: "laptopcomputer", iconTint: .teal) {
                    HStack(spacing: 8) {
                        LiquidSegmentedPicker(
                            title: "Docker 运行环境",
                            selection: $context,
                            options: [
                                LiquidMenuOption(value: "desktop-linux", label: "Docker Desktop"),
                                LiquidMenuOption(value: "colima", label: "Colima")
                            ]
                        )
                        .onChange(of: context) { _, _ in
                            snapshot = nil
                            extras = nil
                            extrasError = nil
                            applyColima = context == "colima"
                            problem = nil
                            message = nil
                            refresh()
                        }
                        Button(loading ? "读取中…" : "刷新状态") { refresh() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(loading || runningOperation)
                    }
                }
                if let snapshot {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "引擎版本", icon: "checkmark.circle.fill", iconTint: .green) {
                        Text(snapshot.engineVersion).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                    if !snapshot.registryMirrors.isEmpty {
                        IsleGroupSpacing(height: 4).padding(.leading, 14)
                        AppleSettingsRow(title: "当前生效的镜像源", icon: "arrow.down.circle.fill", iconTint: .cyan) {
                            Text(snapshot.registryMirrors.joined(separator: "、"))
                                .font(.caption.monospaced())
                                .foregroundStyle(IsleTheme.secondaryText)
                                .textSelection(.enabled)
                        }
                    }
                }
                if let problem {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "引擎状态提示", icon: "exclamationmark.triangle.fill", iconTint: .orange) {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(IsleTheme.warningText)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }

        }
    }
    private var composeSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(title: "Compose 项目", footer: "支持选择本机 Compose YAML 文件创建新项目，并管理已存在项目。每项操作均需用户确认；不提供 down -v 或批量删除。项目配置必须位于当前 Mac 用户目录。") {
                AppleSettingsRow(
                    title: "导入本地 Compose 配置",
                    subtitle: "仅选择你信任的本地 YAML 文件；可能挂载宿主目录或映射端口",
                    icon: "doc.badge.gearshape.fill",
                    iconTint: .purple
                ) {
                    HStack(spacing: 8) {
                        Button("选择 Compose 配置…") { chooseComposeFiles() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        if !importedComposePaths.isEmpty {
                            Button("取消选择") { importedComposePaths = []; importedComposeName = "" }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                    }
                }
                if !importedComposePaths.isEmpty {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(importedComposePaths.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .foregroundStyle(IsleTheme.secondaryText)
                            .textSelection(.enabled)
                        HStack(spacing: 8) {
                            TextField("Compose 项目名称（英文小写字母、数字、-、_）", text: $importedComposeName)
                                .liquidInput()
                            Button(runningOperation ? "部署中…" : "部署新 Compose 项目…") {
                                deployImportedCompose()
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                            .disabled(runningOperation || snapshot == nil || importedComposeName.isEmpty)
                        }
                        Text("会检查 Compose 文件，并在确认后创建容器、网络及数据卷；可能拉取缺失镜像，不会构建 Dockerfile 或覆盖已有同名项目。")
                            .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                VStack(alignment: .leading, spacing: 10) {
                    if extrasLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读取 Compose 项目…").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        }
                    } else if let extras {
                        if !extras.composeAvailable {
                            Text("未检测到 Docker Compose 插件，可先通过 Docker Desktop 或独立 Docker CLI 安装。")
                                .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        } else if extras.projects.isEmpty {
                            Text("没有发现 Compose 项目。请先使用自己的 Compose 文件完成部署。")
                                .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        } else {
                            ForEach(extras.projects.prefix(100)) { project in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(project.name).font(.system(size: 13, weight: .semibold))
                                        Spacer()
                                        Text(project.status)
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                                            .foregroundStyle(IsleTheme.secondaryText)
                                    }
                                    if !project.configFiles.isEmpty {
                                        Text(project.configFiles.joined(separator: "\n"))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(IsleTheme.secondaryText)
                                            .textSelection(.enabled)
                                    }
                                    HStack(spacing: 8) {
                                        Button("启动") { operateCompose("start", project: project) }
                                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                        Button("停止") { operateCompose("stop", project: project) }
                                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                        Button("重启") { operateCompose("restart", project: project) }
                                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    }
                                    .disabled(runningOperation)
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.primary.opacity(0.03))
                                )
                            }
                        }
                    } else {
                        Text("刷新 Docker 引擎后读取本地 Compose 项目。")
                            .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                    if let extrasError {
                        Text(extrasError).font(.caption).foregroundStyle(IsleTheme.warningText).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
    }
    private var resourcesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(title: "Docker 数据卷与网络", footer: "可明确确认后创建本地空数据卷或 bridge 网络，并查看已有资源。不会删除、格式化、断开或批量清理，以免误伤 NAS 数据。") {
                AppleSettingsRow(title: "新建本地数据卷", subtitle: "由 Docker 引擎托管，不自动挂载到 NAS 共享文件夹", icon: "externaldrive.badge.plus", iconTint: .indigo) {
                    HStack(spacing: 8) {
                        TextField("新的数据卷名称", text: $newVolumeName)
                            .liquidInput()
                            .frame(width: 190)
                        Button("创建数据卷…") { createResource("volume") }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(runningOperation || snapshot == nil || newVolumeName.isEmpty)
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "新建 bridge 网络", subtitle: "仅允许安全字符名称，执行前会二次确认", icon: "network", iconTint: .cyan) {
                    HStack(spacing: 8) {
                        TextField("新的 bridge 网络名称", text: $newNetworkName)
                            .liquidInput()
                            .frame(width: 190)
                        Button("创建网络…") { createResource("network") }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(runningOperation || snapshot == nil || newNetworkName.isEmpty)
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                VStack(alignment: .leading, spacing: 8) {
                    if let extras {
                        Text("数据卷：\(extras.volumes.count) 个 · 网络：\(extras.networks.count) 个")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(IsleTheme.secondaryText)
                        ForEach(extras.volumes.prefix(50)) { volume in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(volume.name).font(.system(size: 12, weight: .semibold))
                                    Text(volume.mountpoint).font(.caption.monospaced()).foregroundStyle(IsleTheme.secondaryText)
                                        .lineLimit(2).textSelection(.enabled)
                                }
                                Spacer()
                                Text(volume.driver)
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                                    .foregroundStyle(IsleTheme.secondaryText)
                            }
                            .padding(.vertical, 4)
                        }
                        if !extras.volumes.isEmpty && !extras.networks.isEmpty {
                            IsleGroupSpacing(height: 4)
                        }
                        ForEach(extras.networks.prefix(50)) { network in
                            HStack {
                                Text(network.name).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(network.driver + " · " + network.scope)
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                                    .foregroundStyle(IsleTheme.secondaryText)
                            }
                            .padding(.vertical, 4)
                        }
                        if extras.volumes.count > 50 || extras.networks.count > 50 {
                            Text("仅展示前 50 条记录；完整清单请在 Docker CLI 查看。")
                                .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        }
                    } else {
                        Text("连接本机 Docker 引擎后显示数据卷与网络。")
                            .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
    }
    private var imagesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(title: "本地镜像列表", footer: "仅查看本机已有 Docker 镜像及其大小。不会自动执行清理、镜像下载或仓库登录。") {
                VStack(alignment: .leading, spacing: 8) {
                    if let snapshot {
                        if snapshot.images.isEmpty {
                            Text("当前没有本地镜像。").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        }
                        ForEach(snapshot.images.prefix(100)) { image in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(image.repository + ":" + image.tag)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .lineLimit(1)
                                    Text(image.id.prefix(22) + "…")
                                        .font(.caption.monospaced()).foregroundStyle(IsleTheme.secondaryText)
                                }
                                Spacer()
                                Text(image.size)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                                    .foregroundStyle(IsleTheme.secondaryText)
                            }
                            .padding(.vertical, 4)
                            if image.id != snapshot.images.prefix(100).last?.id {
                                IsleGroupSpacing(height: 4)
                            }
                        }
                        if snapshot.images.count > 100 {
                            Text("仅展示前 100 个镜像，更多镜像请通过 Docker Desktop 查看。")
                                .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        }
                    } else {
                        Text("等待本地 Docker 引擎连接。").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

                IsleGroupSpacing(height: 4).padding(.leading, 14)

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.blue.opacity(0.14))
                                .frame(width: 24, height: 24)
                            Image(systemName: "arrow.down.to.line.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(IsleTheme.accent)
                        }
                        Text("拉取 / 检查镜像标签")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    HStack(spacing: 8) {
                        TextField("例如 nginx:stable、redis:7.4 或 ghcr.io/组织/镜像:v1", text: $imageReference)
                            .liquidInput()
                        Button(runningOperation ? "执行中…" : "拉取镜像") { pullImage() }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                            .disabled(runningOperation || loading || snapshot == nil ||
                                      imageReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("重新拉取现有标签可检查镜像是否更新，但不会自动替换或重启已有容器。具体下载速度取决于 Docker 引擎和镜像源。")
                        .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

        }
    }
    private var containersSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(title: "容器列表", footer: "仅允许对当前选中的本地 Docker 上下文执行启动、停止与重启。删除容器、清理数据卷等高风险操作暂不提供。") {
                VStack(alignment: .leading, spacing: 10) {
                    if loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读取本机容器…").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        }
                    } else if let snapshot {
                        if snapshot.containers.isEmpty {
                            Text("目前没有容器。可在 Docker Desktop/Colima 或终端创建，之后点击刷新。")
                                .foregroundStyle(IsleTheme.secondaryText).font(.caption)
                        }
                        ForEach(snapshot.containers) { container in
                            let isRunning = container.state == "running"
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(container.name).font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text(isRunning ? "运行中" : "已停止")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill((isRunning ? Color.green : Color.secondary).opacity(0.12)))
                                        .foregroundStyle(isRunning ? .green : .secondary)
                                }
                                Text(container.image + " · " + container.status + (container.ports.isEmpty ? "" : " · " + container.ports))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(IsleTheme.secondaryText)
                                    .lineLimit(2)
                                HStack(spacing: 8) {
                                    if !isRunning {
                                        Button("启动") { operate("start", container: container) }
                                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                    } else {
                                        if let webURL = container.webURL {
                                            Button("打开网页") { NSWorkspace.shared.open(webURL) }
                                                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                        }
                                        Button("停止") { operate("stop", container: container) }
                                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                        Button("重启") { operate("restart", container: container) }
                                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    }
                                    Button("日志") { loadLogs(for: container) }
                                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    if isRunning {
                                        Button("资源与健康") { loadMetrics(for: container) }
                                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    }
                                }
                                .disabled(runningOperation)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.03))
                            )
                        }
                    } else {
                        Text("选择本机运行环境并刷新状态，查看容器。")
                            .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
    }
    private var mirrorsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(title: "国内 Docker Hub 镜像加速", footer: "只配置 Docker Hub registry-mirrors；不改变 GHCR 等第三方仓库，也不提供私有镜像账号密码管理。公共镜像由第三方提供，可能限流、过期或不同步。") {
                AppleSettingsRow(
                    title: "镜像源模式",
                    subtitle: "可选择国内公共加速预设或填写专属加速域名",
                    icon: "bolt.horizontal.circle.fill",
                    iconTint: .orange
                ) {
                    LiquidSegmentedPicker(
                        title: "镜像源模式",
                        selection: $useCustomMirror,
                        options: [
                            LiquidMenuOption(value: false, label: "预设加速源"),
                            LiquidMenuOption(value: true, label: "自定义地址")
                        ]
                    )
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                if useCustomMirror {
                    AppleSettingsRow(title: "自定义加速地址", icon: "link.circle.fill", iconTint: .blue) {
                        TextField("https://你的专属镜像域名", text: $customMirror)
                            .liquidInput()
                            .frame(width: 260)
                    }
                } else {
                    AppleSettingsRow(
                        title: "镜像加速服务",
                        subtitle: selectedPreset?.note,
                        icon: "globe.asia.australia.fill",
                        iconTint: .cyan
                    ) {
                        LiquidMenuPicker(
                            title: "镜像加速服务",
                            selection: $preset,
                            options: DockerMirrorPreset.catalog.map { item in
                                LiquidMenuOption(value: item.id, label: item.title)
                            },
                            minWidth: 190
                        )
                    }
                    if let chosen = selectedPreset {
                        IsleGroupSpacing(height: 4).padding(.leading, 14)
                        AppleSettingsRow(title: "加速源地址") {
                            if !chosen.url.isEmpty {
                                Text(chosen.url)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(IsleTheme.secondaryText)
                                    .textSelection(.enabled)
                            } else {
                                Text("请从服务商控制台获取专属加速地址，切换到「自定义地址」粘贴。")
                                    .font(.caption).foregroundStyle(IsleTheme.warningText)
                            }
                        }
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(
                    title: "同时配置 Colima 默认虚拟机",
                    subtitle: applyColima
                        ? "同时修改 ~/.colima/default/colima.yaml 与 ~/.docker/daemon.json"
                        : "只更新 ~/.docker/daemon.json（Docker Desktop），不修改内部设置存储",
                    icon: "terminal.fill",
                    iconTint: .purple
                ) {
                    Toggle("", isOn: $applyColima)
                        .toggleStyle(.switch)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "连通性检测与配置写入", subtitle: "覆盖前保留独立备份，不清空 Docker 其他配置", icon: "checkmark.shield.fill", iconTint: .green) {
                    HStack(spacing: 8) {
                        Button(mirrorTesting ? "检测中…" : "测试加速源连接") { testMirror() }
                            .disabled(mirrorTesting || mirror.isEmpty)
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        Button("应用镜像源配置…") { applyMirror() }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                            .disabled(runningOperation || mirror.isEmpty)
                        Button("官方文档") {
                            if let url = URL(string: "https://docs.docker.com/desktop/settings-and-maintenance/settings/") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                }
                .onChange(of: mirror) { _, _ in mirrorTestResult = nil }
                if let mirrorTestResult {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "连接检测结果") {
                        Text(mirrorTestResult)
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                            .textSelection(.enabled)
                    }
                }
            }

        }
    }
}
