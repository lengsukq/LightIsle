import AppKit
import Foundation
import SwiftUI

enum AppsAndContainersSection: String, CaseIterable, Identifiable {
    case plugins = "轻应用与插件"
    case mcp = "MCP 开发者与调试"
    case docker = "Docker 容器"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .plugins: return "square.grid.2x2.fill"
        case .mcp: return "terminal.fill"
        case .docker: return "shippingbox.fill"
        }
    }
}

struct NativeAppAccessConfig: Codable, Equatable {
    var policy: String
    var allowedUserIDs: [Int64]
}

struct NativeAppWebState: Decodable, Equatable {
    let enabled: Bool
    let mode: String
    let runtime: String?
    let entry: String?
    let staticDir: String?
    let basePath: String?
    let status: String
    let pid: Int?
    let port: Int?
    let rssBytes: Int64?
    let startedAt: String?
    let lastAccessAt: String?
    let lastError: String?
    let idleTimeoutSeconds: Int?
    let readyTimeoutSeconds: Int?
    let autoRestart: Bool?
}

struct NativeAppCronNotification: Codable, Equatable {
    var events: [String]
    var channels: [String]
}

struct NativeAppCronState: Equatable {
    let enabled: Bool
    let cron: String
    let timezone: String?
    let timeoutSeconds: Int
    let notification: NativeAppCronNotification
    let running: Bool
}

struct NativeAppDiagnostic: Decodable, Equatable {
    let summary: String
    let reason: String
    let logExcerpt: String?
    let checks: [String]
    let solutions: [String]
    let dataSafe: String
}

struct NativePublicApp: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    let author: String?
    let description: String?
    let category: String?
    let iconUrl: String?
    let revision: String?
    let valid: Bool
    let error: String?
    let lastError: String?
    let diagnostic: NativeAppDiagnostic?
    let pendingActivation: Bool
    let access: NativeAppAccessConfig
    let web: NativeAppWebState
    let cron: NativeAppCronState?
    let envKeys: [String]?

    private enum CodingKeys: String, CodingKey {
        case id, name, version, author, description, category, iconUrl, revision
        case valid, error, validationError, lastError, diagnostic, pendingActivation, access, web, cron, envKeys
    }

    private struct RawCronView: Decodable {
        let hasCron: Bool?
        let enabled: Bool?
        let cron: String?
        let timezone: String?
        let timeoutSeconds: Int?
        let events: [String]?
        let channels: [String]?
        let notification: NativeAppCronNotification?
        let running: Bool?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        iconUrl = try container.decodeIfPresent(String.self, forKey: .iconUrl)
        revision = try container.decodeIfPresent(String.self, forKey: .revision)
        valid = try container.decodeIfPresent(Bool.self, forKey: .valid) ?? true
        error = try container.decodeIfPresent(String.self, forKey: .validationError)
            ?? container.decodeIfPresent(String.self, forKey: .error)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        diagnostic = try container.decodeIfPresent(NativeAppDiagnostic.self, forKey: .diagnostic)
        pendingActivation = try container.decodeIfPresent(Bool.self, forKey: .pendingActivation) ?? false
        access = try container.decode(NativeAppAccessConfig.self, forKey: .access)
        web = try container.decode(NativeAppWebState.self, forKey: .web)
        envKeys = try container.decodeIfPresent([String].self, forKey: .envKeys)

        if let rawCron = try container.decodeIfPresent(RawCronView.self, forKey: .cron),
           rawCron.hasCron != false {
            let notif = rawCron.notification ?? NativeAppCronNotification(
                events: rawCron.events ?? ["failure", "timeout"],
                channels: rawCron.channels ?? []
            )
            cron = NativeAppCronState(
                enabled: rawCron.enabled ?? false,
                cron: rawCron.cron ?? "0 * * * *",
                timezone: rawCron.timezone,
                timeoutSeconds: rawCron.timeoutSeconds ?? 300,
                notification: notif,
                running: rawCron.running ?? false
            )
        } else {
            cron = nil
        }
    }

    var statusLabel: String {
        if !valid { return "配置异常" }
        if pendingActivation { return "待激活确认" }
        switch web.status {
        case "running": return "运行中"
        case "starting": return "启动中"
        case "static": return "静态就绪"
        case "stopped": return web.mode == "on-demand" ? "按需休眠" : "已停止"
        case "crashed": return "进程异常"
        case "disabled": return cron != nil ? "仅定时脚本" : "已停用"
        default: return web.status
        }
    }

    var isRunning: Bool {
        web.status == "running" || web.status == "starting"
    }
}

struct NativeMCPConfigSnapshot: Decodable, Equatable {
    var mcpEnabled: Bool
    var mcpLanEnabled: Bool
    var mcpToken: String?
    var command: String
    var localHttpUrl: String
    var lanHttpUrl: String?
    var lanSseUrl: String?
    var mcpPrompt: String
    var lanMcpPrompt: String
    var mcpConfigJson: String
    var pluginsDir: String
    var pluginDataDir: String
    var updatedAt: String

    static let empty = NativeMCPConfigSnapshot(
        mcpEnabled: false,
        mcpLanEnabled: false,
        mcpToken: nil,
        command: "",
        localHttpUrl: "http://127.0.0.1:16666/api/v2/mcp",
        lanHttpUrl: nil,
        lanSseUrl: nil,
        mcpPrompt: "",
        lanMcpPrompt: "",
        mcpConfigJson: "",
        pluginsDir: "",
        pluginDataDir: "",
        updatedAt: ""
    )
}

struct NativeMCPCallLogEntry: Decodable, Identifiable, Equatable {
    let id: String
    let timestamp: String
    let transport: String
    let remoteAddr: String?
    let method: String
    let target: String?
    let durationMs: Int64
    let isError: Bool
    let requestSummary: String?
    let responsePreview: String?
}

struct NativeAppMember: Decodable, Identifiable, Equatable {
    let id: Int64
    let username: String
    let role: String
}

struct NativeAppCronRun: Decodable, Identifiable, Equatable {
    let id: String
    let state: String?
    let startedAt: String?
    let exitCode: Int?
    let output: String?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case id, state, startedAt, exitCode, output, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        output = try container.decodeIfPresent(String.self, forKey: .output)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        if let epoch = try? container.decodeIfPresent(Int64.self, forKey: .startedAt), epoch > 0 {
            startedAt = Date(timeIntervalSince1970: TimeInterval(epoch)).formatted()
        } else {
            startedAt = try? container.decodeIfPresent(String.self, forKey: .startedAt)
        }
        if let numID = try? container.decodeIfPresent(Int64.self, forKey: .id) {
            id = String(numID)
        } else {
            id = "\(startedAt ?? "")-\(exitCode ?? 0)"
        }
    }
}

struct NativeAppLogsResult: Decodable, Equatable {
    let appId: String
    let webOutput: String
    let cronRuns: [NativeAppCronRun]?
}

struct NativeAppProbeResult: Decodable, Equatable {
    let appId: String
    let mode: String
    let status: String
    let method: String
    let targetPath: String
    let statusCode: Int
    let durationMs: Int64
    let headers: [String: String]?
    let bodyPreview: String
    let truncated: Bool?
    let webLogs: String?
    let error: String?
}

struct NativeMCPDebugExecResult: Decodable, Equatable {
    let requestJson: String
    let responseJson: String
    let durationMs: Int64
    let isError: Bool
    let logs: [NativeMCPCallLogEntry]?
}

struct NativeAppLaunchResult: Decodable, Equatable {
    let appId: String
    let ticket: String
    let launchUrl: String
}

private struct NativeAppsOverviewPayload: Decodable {
    let apps: [NativePublicApp]
    let mcp: NativeMCPConfigSnapshot
    let mcpLogs: [NativeMCPCallLogEntry]?
    let members: [NativeAppMember]?
    let configuredChannels: [String]?
    let appLogs: NativeAppLogsResult?
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

struct NativeAppWebUpdatePayload: Encodable {
    var enabled: Bool?
    var mode: String?
    var idleTimeoutSeconds: Int?
    var autoRestart: Bool?
}

struct NativeAppCronUpdatePayload: Encodable {
    var enabled: Bool?
    var cron: String?
    var timeoutSeconds: Int?
    var notification: NativeAppCronNotification?
}

struct NativeAppUpdatePayload: Encodable {
    var access: NativeAppAccessConfig?
    var web: NativeAppWebUpdatePayload?
    var cron: NativeAppCronUpdatePayload?
    var revision: String?
}

struct NativeAppScaffoldPayload: Encodable {
    var id: String
    var name: String
    var description: String
    var category: String
    var mode: String
    var runtime: String
    var hasCron: Bool
    var cron: String
}

@MainActor
final class NativeAppsModel: ObservableObject {
    @Published var workspaceSection: AppsAndContainersSection = .plugins
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var apps: [NativePublicApp] = []
    @Published private(set) var mcp: NativeMCPConfigSnapshot = .empty
    @Published private(set) var mcpLogs: [NativeMCPCallLogEntry] = []
    @Published private(set) var members: [NativeAppMember] = []
    @Published private(set) var configuredChannels: [String] = []
    @Published var currentLogs: NativeAppLogsResult?
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

    func openPluginDirectory(appID: String? = nil) {
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
        busy = false
        activeRequestID = nil

        if let payload = envelope.result {
            apps = payload.apps
            mcp = payload.mcp
            mcpLogs = payload.mcpLogs ?? []
            members = payload.members ?? []
            configuredChannels = payload.configuredChannels ?? []
            if let logs = payload.appLogs {
                currentLogs = logs
            }
            if let probe = payload.probeResult {
                lastProbeResult = probe
            }
            if let debugRes = payload.mcpDebugResult {
                lastMCPDebugResult = debugRes
            }
            if let ticket = payload.launchTicket, let url = URL(string: ticket.launchUrl) {
                NSWorkspace.shared.open(url)
            }
        }

        if let err = envelope.error, !err.isEmpty {
            errorMessage = err
            return
        }
        errorMessage = nil

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
