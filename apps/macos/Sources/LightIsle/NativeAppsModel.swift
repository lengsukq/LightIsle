import AppKit
import Foundation
import SwiftUI

private struct NativeAppsOverviewPayload: Decodable {
    let apps: [NativePublicApp]
    let templates: [NativeOfficialAppTemplate]?
    let appStorage: NativeAppStorageSnapshot?
    let mcp: NativeMCPConfigSnapshot
    let mcpLogs: [NativeMCPCallLogEntry]?
    let members: [NativeAppMember]?
    let configuredChannels: [String]?
    let automationTasks: [NativeAutomationTask]?
    let automationScriptsDir: String?
    let appLogs: NativeAppLogsResult?
    let automationRuns: NativeAutomationRunsResult?
    let probeResult: NativeAppProbeResult?
    let mcpDebugResult: NativeMCPDebugExecResult?
    let launchTicket: NativeAppLaunchResult?
    let backupPath: String?
}

private struct NativeAppsEnvelope: Decodable {
    let schemaVersion: Int
    let operation: String
    let requestID: String?
    let result: NativeAppsOverviewPayload?
    let error: String?
}

@MainActor
final class NativeAppsModel: ObservableObject {
    @Published var workspaceSection: AppsAndContainersSection = .plugins
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var apps: [NativePublicApp] = []
    @Published private(set) var templates: [NativeOfficialAppTemplate] = []
    @Published private(set) var appStorage: NativeAppStorageSnapshot?
    @Published private(set) var mcp: NativeMCPConfigSnapshot = .empty
    @Published private(set) var mcpLogs: [NativeMCPCallLogEntry] = []
    @Published private(set) var members: [NativeAppMember] = []
    @Published private(set) var configuredChannels: [String] = []
    @Published private(set) var automationTasks: [NativeAutomationTask] = []
    @Published private(set) var automationScriptsDir: String = ""
    @Published var currentLogs: NativeAppLogsResult?
    @Published var currentAutomationRuns: NativeAutomationRunsResult?
    @Published var lastProbeResult: NativeAppProbeResult?
    @Published var lastMCPDebugResult: NativeMCPDebugExecResult?
    @Published var message: String?
    @Published var errorMessage: String?

    private var writer: ((String) throws -> Void)?
    private var activeRequestID: String?
    private var timeoutTask: Task<Void, Never>?

    func connect(_ writer: @escaping (String) throws -> Void) {
        self.writer = writer
        connected = true
        refresh()
    }

    func disconnect() {
        timeoutTask?.cancel()
        timeoutTask = nil
        writer = nil
        connected = false
        busy = false
        activeRequestID = nil
    }

    func refresh() {
        sendRawDict(operation: "list", payload: [:])
    }

    func reloadApps() {
        sendRawDict(operation: "refresh", payload: [:])
    }

    func setMCPConfig(mcpEnabled: Bool? = nil, mcpLanEnabled: Bool? = nil) {
        var dict: [String: Any] = [:]
        if let mcpEnabled {
            dict["mcpEnabled"] = mcpEnabled
            if !mcpEnabled && mcpLanEnabled == nil {
                dict["mcpLanEnabled"] = false
            }
        }
        if let mcpLanEnabled { dict["mcpLanEnabled"] = mcpLanEnabled }
        sendRawDict(operation: "set-mcp", payload: dict)
    }

    func rotateMCPToken() {
        sendRawDict(operation: "rotate-mcp-token", payload: [:])
    }

    func performAppAction(appID: String, action: String) {
        sendRawDict(operation: "action", payload: ["appID": appID, "action": action])
    }

    func updateApp(appID: String, update: NativeAppUpdatePayload) {
        sendEncodable(operation: "update", field: "update", value: update, extra: ["appID": appID])
    }

    func scaffoldApp(_ scaffold: NativeAppScaffoldPayload) {
        sendEncodable(operation: "scaffold", field: "scaffold", value: scaffold)
    }

    func installTemplate(id: String, locationID: String? = nil) {
        var payload: [String: Any] = ["templateId": id]
        if let locationID, !locationID.isEmpty {
            payload["locationId"] = locationID
        }
        sendRawDict(operation: "install-template", payload: payload)
    }

    func mutateAppStorage(
        action: String,
        kind: String? = nil,
        path: String? = nil,
        name: String? = nil,
        defaultLocationID: String? = nil,
        setDefault: Bool? = nil
    ) {
        var storageObj: [String: Any] = ["action": action]
        if let kind, !kind.isEmpty { storageObj["kind"] = kind }
        if let path, !path.isEmpty { storageObj["path"] = path }
        if let name, !name.isEmpty { storageObj["name"] = name }
        if let defaultLocationID, !defaultLocationID.isEmpty { storageObj["defaultLocationId"] = defaultLocationID }
        if let setDefault { storageObj["setDefault"] = setDefault }
        sendRawDict(operation: "set-storage", payload: ["storage": storageObj])
    }

    func setAppStorageWithPermission(
        action: String,
        kind: String,
        path: String,
        name: String? = nil,
        setDefault: Bool = false
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let access = await StoragePermissionHelper.requestReadWriteAccess(
                forPath: path,
                reason: "轻屿应用中心需要获取所选目录及其磁盘卷的读写权限，以便存放轻应用插件（plugins）和业务数据（plugin-data）。"
            )
            if !access.ok {
                self.errorMessage = access.errorMessage ?? "未取得目录读写权限，操作已取消。"
                return
            }
            self.mutateAppStorage(
                action: action,
                kind: kind,
                path: path,
                name: name,
                setDefault: setDefault
            )
        }
    }

    func deleteApp(appID: String, deleteData: Bool) {
        sendRawDict(operation: "delete", payload: ["appID": appID, "deleteData": deleteData])
    }

    func loadLogs(appID: String) {
        sendRawDict(operation: "logs", payload: ["appID": appID])
    }

    func probeApp(appID: String, method: String, path: String, body: String, role: String) {
        sendRawDict(operation: "probe", payload: [
            "appID": appID,
            "probe": ["method": method, "path": path, "body": body, "role": role]
        ])
    }

    func executeMCPDebug(method: String, tool: String, uri: String, argsJSON: String, rawRPC: String) {
        var debugObj: [String: Any] = [
            "method": method,
            "tool": tool,
            "uri": uri,
            "rawRpc": rawRPC
        ]
        if let data = argsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            debugObj["args"] = parsed
        }
        sendRawDict(operation: "mcp-debug", payload: ["mcpDebug": debugObj])
    }

    func clearMCPLogs() {
        sendRawDict(operation: "mcp-clear-logs", payload: [:])
    }

    func openAppInBrowser(appID: String) {
        sendRawDict(operation: "issue-ticket", payload: ["appID": appID])
    }

    func exportAppData(appID: String, to filePath: String) {
        sendRawDict(operation: "export-data", payload: ["appID": appID, "filePath": filePath])
    }

    func restoreAppData(appID: String, from filePath: String) {
        sendRawDict(operation: "restore-data", payload: ["appID": appID, "filePath": filePath])
    }

    func reloadAutomationScripts() {
        sendRawDict(operation: "automation-refresh", payload: [:])
    }

    func updateAutomationTask(
        taskID: String,
        enabled: Bool,
        cron: String,
        timezone: String,
        events: [String],
        channels: [String],
        revision: String?
    ) {
        let updateObj: [String: Any] = [
            "enabled": enabled,
            "revision": revision ?? "",
            "schedule": [
                "cron": cron.trimmingCharacters(in: .whitespacesAndNewlines),
                "timezone": timezone.trimmingCharacters(in: .whitespacesAndNewlines)
            ],
            "notification": [
                "events": events,
                "channels": channels
            ]
        ]
        sendRawDict(operation: "automation-update", payload: [
            "automationTaskId": taskID,
            "automationUpdate": updateObj
        ])
    }

    func runAutomationTaskNow(taskID: String) {
        sendRawDict(operation: "automation-run", payload: ["automationTaskId": taskID])
    }

    func deleteAutomationTask(taskID: String) {
        sendRawDict(operation: "automation-delete", payload: ["automationTaskId": taskID])
    }

    func loadAutomationRuns(taskID: String) {
        sendRawDict(operation: "automation-runs", payload: ["automationTaskId": taskID])
    }

    func openAutomationScriptsDirectory(taskID: String? = nil) {
        let baseDir = !automationScriptsDir.isEmpty
            ? automationScriptsDir
            : ((NativeMetadataRecovery.privateMetadataDirectory ?? (NSHomeDirectory() + "/Library/Application Support/LightIsle")) + "/automation/scripts")
        var url = URL(fileURLWithPath: baseDir, isDirectory: true)
        if let taskID, !taskID.isEmpty {
            url.appendPathComponent(taskID, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(url)
    }

    func openPluginDirectory(appID: String? = nil) {
        if let appID, !appID.isEmpty,
           let matched = apps.first(where: { $0.id == appID }),
           let explicitDir = matched.pluginsDir, !explicitDir.isEmpty {
            let url = URL(fileURLWithPath: explicitDir, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(url)
            return
        }
        let baseDir = !mcp.pluginsDir.isEmpty
            ? mcp.pluginsDir
            : ((NativeMetadataRecovery.privateMetadataDirectory ?? (NSHomeDirectory() + "/Library/Application Support/LightIsle")) + "/plugins")
        var url = URL(fileURLWithPath: baseDir, isDirectory: true)
        if let appID, !appID.isEmpty {
            url.appendPathComponent(appID, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(url)
    }

    func openPluginDataDirectory(appID: String? = nil) {
        if let appID, !appID.isEmpty,
           let matched = apps.first(where: { $0.id == appID }),
           let explicitDir = matched.pluginDataDir, !explicitDir.isEmpty {
            let url = URL(fileURLWithPath: explicitDir, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(url)
            return
        }
        let baseDir = !mcp.pluginDataDir.isEmpty
            ? mcp.pluginDataDir
            : ((NativeMetadataRecovery.privateMetadataDirectory ?? (NSHomeDirectory() + "/Library/Application Support/LightIsle")) + "/plugin-data")
        var url = URL(fileURLWithPath: baseDir, isDirectory: true)
        if let appID, !appID.isEmpty {
            url.appendPathComponent(appID, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(url)
    }

    func consume(_ raw: String) {
        guard let data = Data(base64URLEncoded: raw),
              let envelope = try? JSONDecoder().decode(NativeAppsEnvelope.self, from: data) else {
            busy = false
            errorMessage = "无法解析轻应用与 MCP 状态响应。"
            return
        }
        if let reqID = envelope.requestID, !reqID.isEmpty,
           let active = activeRequestID, reqID != active {
            return
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        if busy { busy = false }
        activeRequestID = nil

        if let payload = envelope.result {
            if !connected { connected = true }
            if apps != payload.apps { apps = payload.apps }
            if let nextTemplates = payload.templates, templates != nextTemplates {
                templates = nextTemplates
            }
            if let storage = payload.appStorage, appStorage != storage {
                appStorage = storage
            }
            if mcp != payload.mcp { mcp = payload.mcp }
            let nextLogs = payload.mcpLogs ?? []
            if mcpLogs != nextLogs { mcpLogs = nextLogs }
            let nextMembers = payload.members ?? []
            if members != nextMembers { members = nextMembers }
            let nextChannels = payload.configuredChannels ?? []
            if configuredChannels != nextChannels { configuredChannels = nextChannels }
            if let tasks = payload.automationTasks, automationTasks != tasks {
                automationTasks = tasks
            }
            if let scriptsDir = payload.automationScriptsDir, !scriptsDir.isEmpty,
               automationScriptsDir != scriptsDir {
                automationScriptsDir = scriptsDir
            }
            if let logs = payload.appLogs, currentLogs != logs {
                currentLogs = logs
            }
            if let autoRuns = payload.automationRuns, currentAutomationRuns != autoRuns {
                currentAutomationRuns = autoRuns
            }
            if let probe = payload.probeResult, lastProbeResult != probe {
                lastProbeResult = probe
            }
            if let debugRes = payload.mcpDebugResult, lastMCPDebugResult != debugRes {
                lastMCPDebugResult = debugRes
            }
            if let ticket = payload.launchTicket, let url = URL(string: ticket.launchUrl) {
                NSWorkspace.shared.open(url)
            }
        }

        if let err = envelope.error, !err.isEmpty {
            if errorMessage != err { errorMessage = err }
            return
        }
        if errorMessage != nil { errorMessage = nil }

        switch envelope.operation {
        case "refresh":
            message = "已重新扫描 plugins 目录并同步轻应用状态。"
        case "set-mcp":
            message = mcp.mcpLanEnabled
                ? "已开启本机与局域网 MCP 开发者服务。"
                : (mcp.mcpEnabled ? "已开启本机 MCP 开发者服务。" : "已关闭 MCP 开发者服务。")
        case "rotate-mcp-token":
            message = "已轮换 MCP 鉴权 Token，请更新局域网 Agent 配置。"
        case "scaffold":
            message = "已创建轻应用脚手架并完成激活。"
        case "install-template":
            message = "已一键安装官方精选轻应用。"
        case "set-storage":
            message = "已更新应用数据存储位置配置。"
        case "update":
            message = "已保存轻应用权限与运行配置。"
        case "delete":
            message = "已卸载该轻应用。"
        case "mcp-clear-logs":
            message = "已清空 MCP 调试调用日志。"
        case "export-data":
            if let path = envelope.result?.backupPath {
                message = "已导出插件数据备份：\(path)"
            }
        case "restore-data":
            if let path = envelope.result?.backupPath {
                message = "已从归档恢复插件数据：\(path)"
            }
        case "automation-refresh":
            message = "已重新扫描 automation/scripts 并同步本机定时脚本。"
        case "automation-update":
            message = "已保存定时脚本设置；脚本源码与邮件模板未受改动。"
        case "automation-run":
            message = "已触发定时脚本立即执行，可在运行日志中查看结果。"
        case "automation-delete":
            message = "已删除该定时脚本任务目录。"
        default:
            break
        }
    }

    private func sendEncodable<T: Encodable>(operation: String, field: String, value: T, extra: [String: Any] = [:]) {
        guard let data = try? JSONEncoder().encode(value),
              let encodedObj = try? JSONSerialization.jsonObject(with: data) else {
            errorMessage = "无法编码轻应用请求参数。"
            return
        }
        var payload = extra
        payload[field] = encodedObj
        sendRawDict(operation: operation, payload: payload)
    }

    private func sendRawDict(operation: String, payload: [String: Any]) {
        guard let writer else {
            errorMessage = "核心服务尚未就绪，请等待 LightIsle 启动完成。"
            return
        }
        let reqID = UUID().uuidString
        var mutable = payload
        mutable["requestID"] = reqID
        guard let jsonBytes = try? JSONSerialization.data(withJSONObject: mutable) else {
            errorMessage = "无法编码轻应用请求参数。"
            return
        }
        do {
            busy = true
            activeRequestID = reqID
            try writer("apps \(operation) \(jsonBytes.base64URLEncodedString)\n")
            scheduleTimeout(for: reqID)
        } catch {
            busy = false
            activeRequestID = nil
            errorMessage = "无法向 Core 发送指令，请检查服务运行状态。"
        }
    }

    private func scheduleTimeout(for requestID: String) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(36))
            guard let self, !Task.isCancelled, self.activeRequestID == requestID else { return }
            self.busy = false
            self.activeRequestID = nil
            self.errorMessage = "轻应用或 MCP 操作响应超时，请刷新重试。"
        }
    }
}
