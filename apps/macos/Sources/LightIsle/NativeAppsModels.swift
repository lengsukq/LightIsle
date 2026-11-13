import Foundation
import SwiftUI

enum AppsAndContainersSection: String, CaseIterable, Identifiable {
    case plugins = "轻应用与插件"
    case automation = "本机定时脚本"
    case mcp = "MCP 开发者与调试"
    case docker = "Docker 容器"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .plugins: return "square.grid.2x2.fill"
        case .automation: return "clock.badge.checkmark.fill"
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

struct NativeOfficialAppTemplate: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    let category: String
    let description: String
    let defaultScope: String?
    let installed: Bool
}

struct NativeAppStorageLocation: Decodable, Identifiable, Equatable {
    let id: String
    let kind: String
    let name: String
    let path: String
    let pluginsDir: String
    let pluginDataDir: String
    let isDefault: Bool
    let isCustomPath: Bool
    let online: Bool
    let writable: Bool
    let error: String?
    let volumeName: String?
    let volumeMount: String?
    let volumeUuid: String?
    let freeBytes: UInt64?
    let totalBytes: UInt64?
    let appCount: Int
}

struct NativeAppStorageVolumeOption: Decodable, Identifiable, Equatable {
    var id: String { mount }
    let name: String
    let mount: String
    let suggestedPath: String
    let filesystem: String?
    let totalBytes: UInt64
    let freeBytes: UInt64
    let readOnly: Bool
    let volumeUuid: String?
}

struct NativeAppStorageSnapshot: Decodable, Equatable {
    let defaultLocationId: String
    let maxInternal: Int
    let maxExternal: Int
    let maxLocations: Int
    let hasExternal: Bool
    let locations: [NativeAppStorageLocation]
    let availableVolumes: [NativeAppStorageVolumeOption]
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
    let locationId: String
    let locationKind: String
    let locationName: String
    let pluginsDir: String?
    let pluginDataDir: String?
    let access: NativeAppAccessConfig
    let web: NativeAppWebState
    let cron: NativeAppCronState?
    let envKeys: [String]?

    private enum CodingKeys: String, CodingKey {
        case id, name, version, author, description, category, iconUrl, revision
        case valid, error, validationError, lastError, diagnostic, pendingActivation
        case locationId, locationKind, locationName, pluginsDir, pluginDataDir
        case access, web, cron, envKeys
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
        locationId = try container.decodeIfPresent(String.self, forKey: .locationId) ?? "internal"
        locationKind = try container.decodeIfPresent(String.self, forKey: .locationKind) ?? "internal"
        locationName = try container.decodeIfPresent(String.self, forKey: .locationName) ?? "Mac 内置盘"
        pluginsDir = try container.decodeIfPresent(String.self, forKey: .pluginsDir)
        pluginDataDir = try container.decodeIfPresent(String.self, forKey: .pluginDataDir)
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
    private static let dateTimeStyle = Date.FormatStyle.dateTime

    let id: String
    let state: String?
    let startedAt: String?
    let finishedAt: String?
    let exitCode: Int?
    let output: String?
    let error: String?
    let deliveries: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case id, state, startedAt, finishedAt, exitCode, output, error, deliveries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        output = try container.decodeIfPresent(String.self, forKey: .output)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        deliveries = try container.decodeIfPresent([String: String].self, forKey: .deliveries)
        if let epoch = try? container.decodeIfPresent(Int64.self, forKey: .startedAt), epoch > 0 {
            startedAt = Self.dateTimeStyle.format(Date(timeIntervalSince1970: TimeInterval(epoch)))
        } else {
            startedAt = try? container.decodeIfPresent(String.self, forKey: .startedAt)
        }
        if let epoch = try? container.decodeIfPresent(Int64.self, forKey: .finishedAt), epoch > 0 {
            finishedAt = Self.dateTimeStyle.format(Date(timeIntervalSince1970: TimeInterval(epoch)))
        } else {
            finishedAt = try? container.decodeIfPresent(String.self, forKey: .finishedAt)
        }
        if let numID = try? container.decodeIfPresent(Int64.self, forKey: .id) {
            id = String(numID)
        } else {
            id = "\(startedAt ?? "")-\(exitCode ?? 0)"
        }
    }
}

struct NativeAutomationSchedule: Codable, Equatable {
    var cron: String
    var timezone: String
}

struct NativeAutomationNotification: Codable, Equatable {
    var events: [String]?
    var channels: [String]?
}

struct NativeAutomationRunSummary: Decodable, Equatable {
    let startedAt: Int64
    let finishedAt: Int64
    let state: String
    let exitCode: Int
}

struct NativeAutomationTask: Decodable, Identifiable, Equatable {
    let schemaVersion: Int
    let id: String
    let name: String
    let description: String?
    let enabled: Bool
    let entry: String
    let schedule: NativeAutomationSchedule
    let timeoutSeconds: Int?
    let notification: NativeAutomationNotification?
    let running: Bool?
    let nextRun: Int64?
    let lastError: String?
    let revision: String?
    let lastRun: NativeAutomationRunSummary?

    var isRunning: Bool { running ?? false }
}

struct NativeAutomationRunsResult: Decodable, Equatable {
    let taskId: String
    let runs: [NativeAppCronRun]
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
    var locationId: String?
    var hasCron: Bool
    var cron: String
}
