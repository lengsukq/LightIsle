import SwiftUI
import AppKit

extension DockerManagementView {
    func trackEdits() {
        edits.dirty = dirty
        edits.save = {
            guard !otherInputs else { edits.error = "此页有尚未执行的任务输入。请先完成对应操作，或选择放弃输入。"; return }
            applyMirror()
            edits.busy = runningOperation
            if !runningOperation { edits.error = problem ?? "已取消应用配置，修改仍保留在当前页面。" }
        }
        edits.discard = {
            if mirrorBaseline.count == 4 {
                preset = mirrorBaseline[0]; customMirror = mirrorBaseline[1]
                useCustomMirror = mirrorBaseline[2] == "true"; applyColima = mirrorBaseline[3] == "true"
            }
            imageReference = ""; importedComposePaths = []; importedComposeName = ""; newVolumeName = ""; newNetworkName = ""
            edits.dirty = false; edits.error = nil
        }
    }

    func loadMetrics(for container: DockerContainer) {
        guard !AppModel.shared.isPresentationPreview else { problem = "设计预览仅展示界面，不执行本机或网络操作。"; return }
        guard !metricsLoading else { return }
        metricsContainer = container
        containerMetrics = nil
        metricsError = nil
        metricsLoading = true
        showingMetrics = true
        let selected = context
        Task {
            let outcome: Result<DockerContainerMetrics, Error> = await Task.detached(priority: .utility) {
                Result { try DockerOperations.metrics(containerID: container.id, context: selected) }
            }.value
            metricsLoading = false
            guard showingMetrics, selected == context, metricsContainer?.id == container.id else { return }
            switch outcome {
            case .success(let value): containerMetrics = value
            case .failure(let issue): metricsError = "无法获取容器指标：" + issue.localizedDescription
            }
        }
    }

    func createResource(_ kind: String) {
        guard !AppModel.shared.isPresentationPreview else { problem = "设计预览仅展示界面，不执行本机或网络操作。"; return }
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
                if detail == .resources || detail == .images || detail == .compose { refreshExtras(context: selected) }
            case .failure(let error):
                problem = "创建 Docker 资源失败：" + error.localizedDescription
            }
        }
    }

    func chooseComposeFiles() {
        guard !AppModel.shared.isPresentationPreview else { problem = "设计预览仅展示界面，不执行本机或网络操作。"; return }
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

    func deployImportedCompose() {
        guard !AppModel.shared.isPresentationPreview else { problem = "设计预览仅展示界面，不执行本机或网络操作。"; return }
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

    func refresh() {
        guard !AppModel.shared.isPresentationPreview else { problem = "设计预览仅展示界面，不执行本机或网络操作。"; return }
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
                if detail == .resources || detail == .images || detail == .compose { refreshExtras(context: selected) }
            case .failure(let error):
                snapshot = nil
                problem = "本机引擎暂不可用：" + error.localizedDescription
            }
        }
    }

    func refreshExtras(context selected: String) {
        guard !AppModel.shared.isPresentationPreview else { problem = "设计预览仅展示界面，不执行本机或网络操作。"; return }
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

    func loadLogs(for container: DockerContainer) {
        guard !AppModel.shared.isPresentationPreview else { problem = "设计预览仅展示界面，不执行本机或网络操作。"; return }
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

    func pullImage() {
        guard !AppModel.shared.isPresentationPreview else { problem = "设计预览仅展示界面，不执行本机或网络操作。"; return }
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

    func operateCompose(_ action: String, project: DockerComposeProject) {
        guard !AppModel.shared.isPresentationPreview else { problem = "设计预览仅展示界面，不执行本机或网络操作。"; return }
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

    func operate(_ action: String, container: DockerContainer) {
        guard !AppModel.shared.isPresentationPreview else { problem = "设计预览仅展示界面，不执行本机或网络操作。"; return }
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

    func applyMirror() {
        guard !AppModel.shared.isPresentationPreview else { problem = "设计预览仅展示界面，不执行本机或网络操作。"; return }
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
            case .success(let description):
                mirrorBaseline = mirrorFields
                edits.dirty = otherInputs; edits.error = nil
                message = description
            case .failure(let error):
                problem = "镜像源配置失败：" + error.localizedDescription
                edits.error = problem
            }
        }
    }

    func testMirror() {
        guard !AppModel.shared.isPresentationPreview else { problem = "设计预览仅展示界面，不执行本机或网络操作。"; return }
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
