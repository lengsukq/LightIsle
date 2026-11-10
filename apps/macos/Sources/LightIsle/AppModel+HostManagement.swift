import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
extension AppModel {
    // MARK: - Window and background lifecycle

    func setDiagnosticsVisible(_ visible: Bool) {
        guard diagnosticsVisible != visible else { return }
        diagnosticsVisible = visible
        if samplesManagementUI { refreshMetrics() }
    }

    func rebuildMediaIndexes() {
        guard state == .online, !activatingMetadata, backupStatus?.running != true else {
            reindexRequestMessage = "数据库恢复或备份期间不能重新扫描。"
            return
        }
        do {
            try coreCommands?.write(contentsOf: Data("index scan\n".utf8))
            reindexRequestMessage = "已请求后台扫描照片和影视目录。此操作不恢复已丢失的原始文件，不删除私人相册配置。"
        } catch {
            reindexRequestMessage = "无法请求扫描，请检查 Core 服务状态。"
        }
    }

    func setNativeAlertsEnabled(_ enabled: Bool) {
        guard enabled else {
            nativeAlertsEnabled = false
            UserDefaults.standard.set(false, forKey: "lightisle.nativeAlertsEnabled")
            nativeAlertError = nil
            return
        }
        guard !alertAuthorizationPending else { return }
        alertAuthorizationPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let allowed = await nativeAlertCoordinator.requestPermission()
            self.alertAuthorizationPending = false
            self.nativeAlertsEnabled = allowed
            self.nativeAlertError = allowed ? nil : "macOS 未授权轻屿发送通知，请在系统设置 → 通知中检查。"
            UserDefaults.standard.set(allowed, forKey: "lightisle.nativeAlertsEnabled")
        }
    }

    func notifyImportantEvent(_ key: String, title: String, message: String) {
        nativeAlertCoordinator.deliverIfEnabled(nativeAlertsEnabled, key: key, title: title, message: message)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
            objectWillChange.send()
        } catch {
            loginItemError = "登录项更改未成功：\(error.localizedDescription)。请在系统设置 → 通用 → 登录项检查。"
        }
    }

    func setKeepAwakeWhileServing(_ enabled: Bool) {
        keepAwakeWhileServing = enabled
        UserDefaults.standard.set(enabled, forKey: "lightisle.keepAwakeWhileServing")
        servicePresence.updateSleepPolicy(serviceOnline: state == .online, keepAwake: enabled)
    }

    func setAutoLightweightOnLock(_ enabled: Bool) {
        autoLightweightOnLock = enabled
        UserDefaults.standard.set(enabled, forKey: LightweightModePolicy.autoOnLockKey)
    }

    func setManagementWindowVisible(_ id: ObjectIdentifier, visible: Bool) {
        let wasSampling = samplesManagementUI
        if visible { visibleManagementWindows.insert(id) }
        else { visibleManagementWindows.remove(id) }
        guard wasSampling != samplesManagementUI else { return }
        if !samplesManagementUI { releaseManagementCaches() }
        // Wake immediately on reopen instead of waiting for a background sleep.
        if state == .online { beginServicePolling() }
    }

    private func releaseManagementCaches() {
        metrics = nil
        metricHistory.removeAll(keepingCapacity: false)
        if !backupInventoryLoading { backupInventory = nil }
        transferHistory.removeAll(keepingCapacity: false)
        if !metadataRollbacksLoading { metadataRollbacks = nil }
        if !upgradePreflightChecking { upgradePreflight = nil }
    }

    func enterLightweightMode() {
        guard !isLightweightMode else { return }
        isLightweightMode = true
        // Menu-bar-only while lightweight: hide the Dock entry rather than
        // leaving an inactive management app alongside other windows.
        NSApplication.shared.setActivationPolicy(.accessory)
        // The Core is deliberately untouched. Discard only UI-oriented caches,
        // and let WindowGroup remove ContentView and its page StateObjects.
        releaseManagementCaches()
        if state == .online { beginServicePolling() }
    }

    func enterLightweightModeOnLock() {
        guard LightweightModePolicy.shouldEnterOnLock(
            automatic: autoLightweightOnLock, alreadyLightweight: isLightweightMode
        ) else { return }
        enterLightweightMode()
    }

    func restoreNormalMode() {
        guard isLightweightMode else { return }
        NSApplication.shared.setActivationPolicy(.regular)
        isLightweightMode = false
        // Restart the slower poll immediately; don't wait for the old 60s sleep.
        if state == .online {
            beginServicePolling()
        }
    }

    func openAutomationScripts() {
        guard let dataDir = NativeMetadataRecovery.privateMetadataDirectory else { return }
        let automation = URL(fileURLWithPath: dataDir, isDirectory: true).appendingPathComponent("automation", isDirectory: true)
        let scripts = automation.appendingPathComponent("scripts", isDirectory: true)
        let candidates = [scripts, automation, URL(fileURLWithPath: dataDir, isDirectory: true)]
        for candidate in candidates {
            if (try? candidate.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                NSWorkspace.shared.open(candidate)
                return
            }
        }
        let alert = NSAlert()
        alert.messageText = "脚本目录尚未创建"
        alert.informativeText = "请先启动轻屿，或从自动化页面刷新。路径：\n\(scripts.path)"
        alert.runModal()
    }

    // MARK: - Local AI Agent (MCP) & Plugins Directory

    private struct AppsMCPConfigFile: Codable {
        var mcpEnabled: Bool
        var updatedAt: String?
    }

    func refreshMCPDeveloperConfig() {
        guard let dataDir = NativeMetadataRecovery.privateMetadataDirectory else { return }
        let configURL = URL(fileURLWithPath: dataDir, isDirectory: true)
            .appendingPathComponent("apps-config.json", isDirectory: false)
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(AppsMCPConfigFile.self, from: data) else {
            if mcpDeveloperEnabled { mcpDeveloperEnabled = false }
            return
        }
        if mcpDeveloperEnabled != decoded.mcpEnabled {
            mcpDeveloperEnabled = decoded.mcpEnabled
        }
    }

    func setMCPDeveloperEnabled(_ enabled: Bool) {
        guard let dataDir = NativeMetadataRecovery.privateMetadataDirectory else {
            mcpStatusMessage = "无法定位 LightIsle 数据目录。"
            return
        }
        let dirURL = URL(fileURLWithPath: dataDir, isDirectory: true)
        let configURL = dirURL.appendingPathComponent("apps-config.json", isDirectory: false)
        let tokenURL = dirURL.appendingPathComponent(".mcp-reload-token", isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: dirURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let payload = AppsMCPConfigFile(
                mcpEnabled: enabled,
                updatedAt: ISO8601DateFormatter().string(from: Date())
            )
            let encoded = try JSONEncoder().encode(payload)
            try encoded.write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            if !enabled {
                try? FileManager.default.removeItem(at: tokenURL)
            }
            mcpDeveloperEnabled = enabled
            mcpStatusMessage = enabled
                ? "已开启本地 AI Agent (MCP) 接入。"
                : "已关闭本地 AI Agent (MCP) 接入。"
        } catch {
            mcpStatusMessage = "保存 MCP 开关状态失败：\(error.localizedDescription)"
        }
    }

    func copyMCPBootstrapPrompt() {
        if !mcpDeveloperEnabled {
            setMCPDeveloperEnabled(true)
        }
        let corePath = ProcessInfo.processInfo.environment["LIGHTISLE_CORE_PATH"]
            ?? Bundle.main.resourceURL?.appendingPathComponent("core/lightisled").path
            ?? "/Applications/LightIsle.app/Contents/Resources/core/lightisled"
        let dataDir = NativeMetadataRecovery.privateMetadataDirectory
            ?? (NSHomeDirectory() + "/Library/Application Support/LightIsle")
        let prompt = """
        请帮我将当前 Mac 上的「LightIsle（轻屿）开发者 MCP Server」安装并注册到你的 MCP 配置文件中：

        - MCP 服务名称：lightisle-dev
        - 传输方式：stdio
        - 可执行命令：\(corePath)
        - 命令参数：["mcp", "--data-dir", "\(dataDir)"]

        操作要求：
        1. 请自动检测你当前所处的 Agent 环境（如 Claude Code、Codex、Cursor 或 Antigravity MCP 配置），写入上述 lightisle-dev MCP 配置；
        2. 配置完成后，请立即调用 lightisle_get_environment 工具和读取 lightisle://specs/plugin-v2 资源，验证连接是否成功；
        3. 今后当我让你为 LightIsle 开发或改造“应用 / 插件 / 定时脚本”时，请始终优先通过该 MCP 读取规范、自动创建脚手架并触发热重载，只在需要我决定产品偏好（如分配给哪位家庭成员、采集频率、通知渠道）时向我提问。
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        mcpStatusMessage = "已复制 MCP 接入提示词（并已开启 MCP 开关），可直接粘贴给 Claude Code / Antigravity / Codex。"
    }

    func openPluginsDirectory() {
        guard let dataDir = NativeMetadataRecovery.privateMetadataDirectory else { return }
        let pluginsURL = URL(fileURLWithPath: dataDir, isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: pluginsURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        NSWorkspace.shared.open(pluginsURL)
    }

    func checkUpgradePreflight() {
        guard !upgradePreflightChecking,
              let directory = NativeMetadataRecovery.privateMetadataDirectory else { return }
        let request = UUID()
        upgradePreflightRequest = request
        upgradePreflightChecking = true
        upgradePreflight = nil
        Task { @MainActor [weak self] in
            let report = await Task.detached(priority: .utility) {
                NativeUpgradePreflight.inspect(URL(fileURLWithPath: directory))
            }.value
            guard let self, self.upgradePreflightRequest == request else { return }
            self.upgradePreflight = report
            self.upgradePreflightChecking = false
        }
    }

    func invalidateTimeMachineDiagnostics() {
        timeMachineDiagnosticsGeneration &+= 1
        timeMachineDiagnostics = nil
        timeMachineChecking = false
    }

    func saveLocalPort(_ text: String) -> Bool {
        guard let value = Int(text), (1024...65535).contains(value) else {
            portError = "端口必须是 1024–65535 之间的整数。"
            return false
        }
        UserDefaults.standard.set(value, forKey: "lightisle.localPort")
        portError = nil
        return true
    }

    func changeConflictingPort(_ text: String, from port: Int) {
        guard corePortConflict == port, core == nil, !corePortRecoveryBusy,
              saveLocalPort(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        launch()
    }

    func inspectConflictingPort(_ port: Int) async -> CorePortListener? {
        guard corePortConflict == port, core == nil, !corePortRecoveryBusy else { return nil }
        corePortRecoveryBusy = true
        defer { corePortRecoveryBusy = false }
        do {
            return try await Task.detached(priority: .utility) { try CorePortListener.inspect(port: port) }.value
        } catch {
            if corePortConflict == port { details = error.localizedDescription }
            return nil
        }
    }

    func clearConflictingPort(_ listener: CorePortListener) async {
        guard corePortConflict == listener.port, preferredLocalPort == listener.port,
              core == nil, !corePortRecoveryBusy else { return }
        corePortRecoveryBusy = true
        do {
            try await Task.detached(priority: .utility) { try listener.forceStop() }.value
            corePortRecoveryBusy = false
            if corePortConflict == listener.port { launch() }
        } catch {
            corePortRecoveryBusy = false
            if corePortConflict == listener.port { details = error.localizedDescription }
        }
    }

    func saveThumbnailCacheMiB(_ value: Int) -> Bool {
        guard Self.thumbnailCacheOptions.contains(value) else {
            thumbnailCacheError = "缩略图缓存必须在 256 MiB–8 GiB 之间。"
            return false
        }
        UserDefaults.standard.set(value, forKey: "lightisle.thumbnailCacheMiB")
        thumbnailCacheError = nil
        return true
    }

    func cancelStartupDeadline() {
        startupDeadlineTask?.cancel()
        startupDeadlineTask = nil
    }

    func startStartupDeadline(generation: UUID) {
        cancelStartupDeadline()
        startupDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.coreStartupDeadlineSeconds))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.coreGeneration == generation,
                  self.state == .starting else { return }
            self.recoverUnresponsiveCore(generation: generation, expected: .starting, message: "核心服务在 20 秒内未报告就绪。")
        }
    }

    func beginServicePolling() {
        servicePollingTask?.cancel()
        servicePollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.refreshMetrics()
                self.refreshMCPDeveloperConfig()
                // A NAS started before its LAN address is assigned should
                // become reachable once Wi-Fi/Ethernet is ready. The policy
                // prevents retries after a manual "off" or hard failure.
                self.enablePreferredLANIfReady()
                do {
                    try await Task.sleep(for: .seconds(
                        LightweightModePolicy.pollingSeconds(isLightweight: self.isLightweightMode, windowVisible: !self.visibleManagementWindows.isEmpty)
                    ))
                } catch {
                    break
                }
            }
        }
    }

    func endServicePolling() {
        servicePollingTask?.cancel()
        servicePollingTask = nil
    }
}
