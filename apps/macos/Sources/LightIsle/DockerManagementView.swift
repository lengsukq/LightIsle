import SwiftUI
import AppKit

// Intentionally lives in the native owner app, not in the remotely reachable
// Web API. Container lifecycle controls can grant effective root inside a VM.
struct DockerManagementView: View {
    @State private var context = "desktop-linux"
    @State private var snapshot: DockerSnapshot?
    @State private var extras: DockerExtras?
    @State private var extrasLoading = false
    @State private var extrasError: String?
    @State private var loading = false
    @State private var runningOperation = false
    @State private var message: String?
    @State private var problem: String?
    @State private var preset = "one-ms"
    @State private var customMirror = ""
    @State private var useCustomMirror = false
    @State private var applyColima = false
    @State private var mirrorTesting = false
    @State private var mirrorTestResult: String?
    @State private var imageReference = ""
    @State private var showingLogs = false
    @State private var logsContainer: DockerContainer?
    @State private var logsContent = ""
    @State private var logsLoading = false
    @State private var logsError: String?
    @State private var importedComposePaths: [String] = []
    @State private var importedComposeName = ""
    @State private var newVolumeName = ""
    @State private var newNetworkName = ""

    private var mirror: String {
        useCustomMirror ? customMirror :
            (DockerMirrorPreset.catalog.first { $0.id == preset }?.url ?? "")
    }

    private func createResource(_ kind: String) {
        let raw = kind == "volume" ? newVolumeName : newNetworkName
        let name: String
        do { name = try DockerOperationValidation.resourceName(raw, kind: kind) }
        catch { problem = error.localizedDescription; return }
        let isVolume = kind == "volume"
        let alert = NSAlert()
        alert.messageText = "创建 Docker " + (isVolume ? "数据卷" : "bridge 网络") + "？"
        alert.informativeText = name +
            "\n将使用当前选中的本地 Docker 引擎创建一个新资源。该资源不会自动删除，也不会自动挂载到轻屿 NAS 的共享目录。"
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runningOperation = true
        problem = nil
        let selected = context
        Task {
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                Result {
                    if isVolume {
                        try DockerOperations.createVolume(name: name, context: selected)
                    } else {
                        try DockerOperations.createNetwork(name: name, context: selected)
                    }
                }
            }.value
            runningOperation = false
            switch result {
            case .success:
                if isVolume { newVolumeName = "" } else { newNetworkName = "" }
                message = "已创建 Docker " + (isVolume ? "数据卷：" : "网络：") + name
                refreshExtras(context: selected)
            case .failure(let error):
                problem = "创建 Docker 资源失败：" + error.localizedDescription
            }
        }
    }

    private func chooseComposeFiles() {
        let chooser = NSOpenPanel()
        chooser.title = "选择 Docker Compose 配置文件"
        chooser.message = "仅选择你信任的本地 YAML 文件。Compose 可能挂载宿主文件夹或映射端口。"
        chooser.canChooseFiles = true
        chooser.canChooseDirectories = false
        chooser.allowsMultipleSelection = true
        guard chooser.runModal() == .OK else { return }
        let paths = chooser.urls.map(\.path)
        do {
            _ = try DockerOperationValidation.projectFilePaths(paths)
            importedComposePaths = paths
            let directory = chooser.urls[0].deletingLastPathComponent().lastPathComponent.lowercased()
            importedComposeName = directory.replacingOccurrences(of: " ", with: "-")
            problem = nil
        } catch {
            importedComposePaths = []
            importedComposeName = ""
            problem = "无法选择 Compose 文件：" + error.localizedDescription
        }
    }

    private func deployImportedCompose() {
        let project = DockerComposeProject(name: importedComposeName, status: "待部署",
                                           configFiles: importedComposePaths)
        do { _ = try DockerOperationValidation.deployArguments(project: project) }
        catch { problem = error.localizedDescription; return }
        let alert = NSAlert()
        alert.messageText = "部署新的 Docker Compose 项目？"
        alert.informativeText = "项目：" + project.name + "\n配置：" +
            project.configFiles.joined(separator: "\n") +
            "\nCompose 将读取此目录下的 .env 等文件，可能创建容器/卷/网络、映射端口或挂载 Mac 文件夹。" +
            "\n仅在你信任配置内容时执行；不会自动重建现有项目、构建镜像或删除资源。"
        alert.addButton(withTitle: "确认部署")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runningOperation = true
        problem = nil
        message = "正在部署 Compose 项目：" + project.name
        let selected = context
        Task {
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                Result { try DockerOperations.deployCompose(project, context: selected) }
            }.value
            runningOperation = false
            switch result {
            case .success:
                importedComposePaths = []
                importedComposeName = ""
                message = "Compose 项目部署成功：" + project.name
                refresh()
            case .failure(let error):
                message = nil
                problem = "Compose 部署失败：" + error.localizedDescription
            }
        }
    }
    private var selectedPreset: DockerMirrorPreset? {
        DockerMirrorPreset.catalog.first { $0.id == preset }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(title: "Docker 引擎与容器", footer: "仅支持当前 Mac 上安装的 Docker Desktop 或 Colima。不会随 LightIsle 启动虚拟机，也不会在退出时停止第三方容器。") {
                let hasCLI = DockerLocalRuntime.executable() != nil
                AppleSettingsRow(title: "本机 Docker CLI", subtitle: "用于检测并操作当前选中的本地容器上下文", icon: "shippingbox.fill", iconTint: .blue) {
                    StatusBadge(isOnline: hasCLI, text: hasCLI ? "已检测到" : "尚未安装")
                }
                Divider().padding(.leading, 14)
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
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "引擎版本", icon: "checkmark.circle.fill", iconTint: .green) {
                        Text(snapshot.engineVersion).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                    if !snapshot.registryMirrors.isEmpty {
                        Divider().padding(.leading, 14)
                        AppleSettingsRow(title: "当前生效的镜像源", icon: "arrow.down.circle.fill", iconTint: .cyan) {
                            Text(snapshot.registryMirrors.joined(separator: "、"))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                if let problem {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "引擎状态提示", icon: "exclamationmark.triangle.fill", iconTint: .orange) {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }

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
                    Divider().padding(.leading, 14)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(importedComposePaths.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
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
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                Divider().padding(.leading, 14)
                VStack(alignment: .leading, spacing: 10) {
                    if extrasLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读取 Compose 项目…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let extras {
                        if !extras.composeAvailable {
                            Text("未检测到 Docker Compose 插件，可先通过 Docker Desktop 或独立 Docker CLI 安装。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if extras.projects.isEmpty {
                            Text("没有发现 Compose 项目。请先使用自己的 Compose 文件完成部署。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(extras.projects.prefix(100)) { project in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(project.name).font(.system(size: 13, weight: .semibold))
                                        Spacer()
                                        Text(project.status)
                                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                                            .foregroundStyle(.secondary)
                                    }
                                    if !project.configFiles.isEmpty {
                                        Text(project.configFiles.joined(separator: "\n"))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
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
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let extrasError {
                        Text(extrasError).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

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
                Divider().padding(.leading, 14)
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
                Divider().padding(.leading, 14)
                VStack(alignment: .leading, spacing: 8) {
                    if let extras {
                        Text("数据卷：\(extras.volumes.count) 个 · 网络：\(extras.networks.count) 个")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(extras.volumes.prefix(50)) { volume in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(volume.name).font(.system(size: 12, weight: .semibold))
                                    Text(volume.mountpoint).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        .lineLimit(2).textSelection(.enabled)
                                }
                                Spacer()
                                Text(volume.driver)
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        if !extras.volumes.isEmpty && !extras.networks.isEmpty {
                            Divider()
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
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        if extras.volumes.count > 50 || extras.networks.count > 50 {
                            Text("仅展示前 50 条记录；完整清单请在 Docker CLI 查看。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("连接本机 Docker 引擎后显示数据卷与网络。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppleSettingsGroup(title: "本地镜像列表", footer: "仅查看本机已有 Docker 镜像及其大小。不会自动执行清理、镜像下载或仓库登录。") {
                VStack(alignment: .leading, spacing: 8) {
                    if let snapshot {
                        if snapshot.images.isEmpty {
                            Text("当前没有本地镜像。").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(snapshot.images.prefix(100)) { image in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(image.repository + ":" + image.tag)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .lineLimit(1)
                                    Text(image.id.prefix(22) + "…")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(image.size)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            if image.id != snapshot.images.prefix(100).last?.id {
                                Divider()
                            }
                        }
                        if snapshot.images.count > 100 {
                            Text("仅展示前 100 个镜像，更多镜像请通过 Docker Desktop 查看。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("等待本地 Docker 引擎连接。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().padding(.leading, 14)

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.blue.opacity(0.14))
                                .frame(width: 24, height: 24)
                            Image(systemName: "arrow.down.to.line.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.blue)
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
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            AppleSettingsGroup(title: "容器列表", footer: "仅允许对当前选中的本地 Docker 上下文执行启动、停止与重启。删除容器、清理数据卷等高风险操作暂不提供。") {
                VStack(alignment: .leading, spacing: 10) {
                    if loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读取本机容器…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let snapshot {
                        if snapshot.containers.isEmpty {
                            Text("目前没有容器。可在 Docker Desktop/Colima 或终端创建，之后点击刷新。")
                                .foregroundStyle(.secondary).font(.caption)
                        }
                        ForEach(snapshot.containers) { container in
                            let isRunning = container.state == "running"
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(container.name).font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text(isRunning ? "运行中" : "已停止")
                                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill((isRunning ? Color.green : Color.secondary).opacity(0.12)))
                                        .foregroundStyle(isRunning ? .green : .secondary)
                                }
                                Text(container.image + " · " + container.status)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                HStack(spacing: 8) {
                                    if !isRunning {
                                        Button("启动") { operate("start", container: container) }
                                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                    } else {
                                        Button("停止") { operate("stop", container: container) }
                                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                        Button("重启") { operate("restart", container: container) }
                                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    }
                                    Button("日志") { loadLogs(for: container) }
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
                    } else {
                        Text("选择本机运行环境并刷新状态，查看容器。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

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
                Divider().padding(.leading, 14)
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
                        Divider().padding(.leading, 14)
                        AppleSettingsRow(title: "加速源地址") {
                            if !chosen.url.isEmpty {
                                Text(chosen.url)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            } else {
                                Text("请从服务商控制台获取专属加速地址，切换到「自定义地址」粘贴。")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                Divider().padding(.leading, 14)
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
                Divider().padding(.leading, 14)
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
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "连接检测结果") {
                        Text(mirrorTestResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
                    .padding(.horizontal, 4)
            }
        }
        .sheet(isPresented: $showingLogs) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("容器日志 · " + (logsContainer?.name ?? ""))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Spacer()
                    Button("关闭") { showingLogs = false }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
                if logsLoading {
                    ProgressView("正在读取最近 200 行日志…")
                }
                if let logsError {
                    Text(logsError).font(.caption).foregroundStyle(.red)
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
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(minWidth: 680, minHeight: 460)
        }
        .task { refresh() }
    }

    private func refresh() {
        guard !loading, !runningOperation else { return }
        loading = true
        problem = nil
        let selected = context
        Task {
            let result: Result<DockerSnapshot, Error> = await Task.detached(priority: .utility) {
                Result { try DockerLocalRuntime.inspect(selected) }
            }.value
            loading = false
            guard selected == context else {
                refresh()
                return
            }
            switch result {
            case .success(let data):
                snapshot = data
                refreshExtras(context: selected)
            case .failure(let error):
                snapshot = nil
                problem = "本机引擎暂不可用：" + error.localizedDescription
            }
        }
    }

    private func refreshExtras(context selected: String) {
        extrasLoading = true
        extrasError = nil
        Task {
            let result: Result<DockerExtras, Error> = await Task.detached(priority: .utility) {
                Result { try DockerOperations.inspectExtras(selected) }
            }.value
            guard selected == context else {
                extrasLoading = false
                return
            }
            extrasLoading = false
            switch result {
            case .success(let state): extras = state
            case .failure(let error):
                extras = nil
                extrasError = "读取 Compose/存储信息失败：" + error.localizedDescription
            }
        }
    }

    private func loadLogs(for container: DockerContainer) {
        logsContainer = container
        logsContent = ""
        logsError = nil
        logsLoading = true
        showingLogs = true
        let selected = context
        Task {
            let result: Result<String, Error> = await Task.detached(priority: .utility) {
                Result { try DockerOperations.logs(containerID: container.id, context: selected) }
            }.value
            logsLoading = false
            guard selected == context && logsContainer?.id == container.id else { return }
            switch result {
            case .success(let text): logsContent = text
            case .failure(let error): logsError = "读取失败：" + error.localizedDescription
            }
        }
    }

    private func pullImage() {
        let reference: String
        do { reference = try DockerOperationValidation.imageReference(imageReference.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { problem = error.localizedDescription; return }
        let alert = NSAlert()
        alert.messageText = "从镜像仓库拉取镜像？"
        alert.informativeText = reference +
            "\n将使用 Docker 当前配置的加速源及已登录凭据，从网络下载数据并占用本机存储。\n不会升级或重启现有容器。"
        alert.addButton(withTitle: "开始拉取")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runningOperation = true
        message = "正在拉取 " + reference + "，最多等待 4 分钟。"
        problem = nil
        let selected = context
        Task {
            let result: Result<String, Error> = await Task.detached(priority: .utility) {
                Result { try DockerOperations.pullImage(reference, context: selected) }
            }.value
            runningOperation = false
            switch result {
            case .success(let detail):
                message = "镜像拉取已完成：" + reference + (detail.isEmpty ? "" : "\n" + String(detail.prefix(350)))
                refresh()
            case .failure(let error):
                problem = "镜像拉取失败：" + error.localizedDescription
                message = nil
            }
        }
    }

    private func operateCompose(_ action: String, project: DockerComposeProject) {
        do { _ = try DockerOperationValidation.composeArguments(project: project, action: action) }
        catch { problem = error.localizedDescription; return }
        let prompt = NSAlert()
        let verb = action == "stop" ? "停止" : action == "restart" ? "重启" : "启动"
        prompt.messageText = "确定" + verb + " Compose 项目？"
        prompt.informativeText = project.name + "\n将对已有服务执行 docker compose " + action +
            "，项目配置：" + project.configFiles.joined(separator: "\n") +
            "\n不会创建新项目或删除卷。操作可能暂时中断应用服务。"
        prompt.addButton(withTitle: "执行")
        prompt.addButton(withTitle: "取消")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        runningOperation = true
        problem = nil
        let selected = context
        Task {
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                Result { try DockerOperations.operateCompose(project, action: action, context: selected) }
            }.value
            runningOperation = false
            switch result {
            case .success:
                message = "Compose 项目操作已完成：" + project.name + " · " + verb
                refresh()
            case .failure(let error):
                problem = "Compose 操作失败：" + error.localizedDescription
            }
        }
    }

    private func operate(_ action: String, container: DockerContainer) {
        guard !runningOperation else { return }
        let prompt = NSAlert()
        prompt.messageText = "确定" + (action == "stop" ? "停止" : action == "restart" ? "重启" : "启动") + "容器？"
        prompt.informativeText = container.name + " · " + container.image +
            "\n此操作仅作用于本机引擎。停止/重启可能导致容器里的服务暂时中断。"
        prompt.addButton(withTitle: "执行")
        prompt.addButton(withTitle: "取消")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        runningOperation = true
        problem = nil
        let selected = context
        Task {
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                Result { try DockerLocalRuntime.operate(action, container: container, context: selected) }
            }.value
            runningOperation = false
            switch result {
            case .success:
                message = "已提交容器操作：" + container.name
                refresh()
            case .failure(let error):
                problem = "容器操作失败：" + error.localizedDescription
            }
        }
    }

    private func applyMirror() {
        guard !runningOperation else { return }
        let endpoint: String
        do { endpoint = try DockerMirrorConfig.validate(mirror) }
        catch { problem = error.localizedDescription; return }
        let alert = NSAlert()
        alert.messageText = "写入本机 Docker 镜像加速源？"
        alert.informativeText = endpoint +
            "\n将备份并修改镜像配置。" +
            (applyColima ? " 会同时修改 Colima 默认实例的 YAML。" : "") +
            "\n不会自动重启引擎、安装 Docker 或拉取镜像。公共镜像可能不受信任或不同步。"
        alert.addButton(withTitle: "备份并应用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runningOperation = true
        problem = nil
        message = nil
        let colima = applyColima
        Task {
            let result: Result<String, Error> = await Task.detached(priority: .utility) {
                Result { try DockerMirrorWriter.apply(mirror: endpoint, toColima: colima) }
            }.value
            runningOperation = false
            switch result {
            case .success(let description): message = description
            case .failure(let error): problem = "镜像源配置失败：" + error.localizedDescription
            }
        }
    }

    private func testMirror() {
        guard !mirrorTesting else { return }
        mirrorTesting = true
        mirrorTestResult = nil
        let source = mirror
        Task {
            do {
                let result = try await DockerMirrorProbe.check(source)
                if source == mirror { mirrorTestResult = result }
            } catch {
                if source == mirror { mirrorTestResult = "连接检测失败：" + error.localizedDescription }
            }
            mirrorTesting = false
        }
    }
}
