import SwiftUI
import Foundation
import AppKit
import Darwin
import LocalAuthentication
import ServiceManagement

enum CoreState: Equatable {
    case offline
    case starting
    case online
    case stopping
    case error(String)

    var label: String {
        switch self {
        case .offline: return "未运行"
        case .starting: return "正在启动"
        case .online: return "正在运行"
        case .stopping: return "正在停止"
        case .error: return "运行异常"
        }
    }
}
struct ManagedDisk: Decodable, Identifiable {
    let id: String
    let name: String
    let mount: String
    let parent: String
    let filesystem: String
    let protocolName: String
    let smart: String
    let total: UInt64
    let free: UInt64
    let readOnly: Bool
    let mounted: Bool
    let external: Bool
    let identity: String
    enum CodingKeys: String, CodingKey {
        case id, name, mount, parent, filesystem, smart, total, free, readOnly, mounted, external, identity
        case protocolName = "protocol"
    }
}
private struct CorePersistentAlert: Decodable {
    let code: String
    let severity: String
    let message: String
    let active: Bool
    let acknowledged: Bool
}

struct FileTransferReceipt: Decodable, Identifiable {
    let id: String
    let source: String
    let destination: String
    let phase: String
    let error: String?
    let startedAt: Int64
    let updatedAt: Int64
    let sourceSize: Int64
    let trashId: String?

    var statusDescription: String {
        switch phase {
        case "source_in_trash": return "已完成 · 源文件在回收站"
        case "published": return "目标已发布 · 请核对源文件位置"
        case "copy_incomplete": return "复制中断 · 源文件保留"
        case "copy_published_unconfirmed": return "目标已出现，落盘未确认 · 源文件保留"
        case "source_changed_restored": return "校验未通过 · 源文件已还原，请核对两个副本"
        case "source_trash_unresolved": return "移动未完成 · 待核对的文件保存在回收站"
        case "source_move_uncertain": return "源文件位置待核对 · 请保留目标与回收站副本"
        case "source_trash_failed": return "移入回收站失败 · 请核对源文件与目标"
        default: return "尚未完成 · 请核对源文件与目标"
        }
    }
}

@MainActor
extension AppModel {
    /// The native owner reviews a count-only preview before authorizing an
    /// offline database activation. The read-only helper can run while Core
    /// owns the data-directory lock.
    func previewRestoredMetadata() {
        guard state == .online, !activatingMetadata, !metadataPreviewLoading,
              backupStatus?.running != true,
              let fullPath = backupStatus?.restoredMetadata,
              let dataDir = Self.privateMetadataDirectory else { return }
        let selected = URL(fileURLWithPath: fullPath).standardizedFileURL
        let privateRoot = URL(fileURLWithPath: dataDir).standardizedFileURL
        guard selected.lastPathComponent.hasPrefix("LightIsle-RestoredMetadata-"),
              selected.deletingLastPathComponent().standardizedFileURL == privateRoot else {
            metadataActivationMessage = "恢复目录不在轻屿的私有数据区域，未读取或修改数据。"
            return
        }

        metadataPreview = nil
        metadataPreviewStageName = nil
        metadataPreviewLoading = true
        metadataActivationMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = LAContext()
            var policyError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
                metadataActivationMessage = "无法验证本机所有者，未读取或修改数据。"
                metadataPreviewLoading = false
                return
            }
            do {
                let approved = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "验证 Mac 所有者身份，以检查待恢复数据库的影响"
                )
                guard approved else { throw NSError(domain: "LightIsle", code: 1) }
                let preview = await Self.runMetadataPreview(dataDir: privateRoot.path, stage: selected.lastPathComponent)
                guard preview.isReady else {
                    metadataActivationMessage = preview.error?.message ?? "无法验证恢复预览，当前数据库未修改。"
                    metadataPreviewLoading = false
                    return
                }
                metadataPreview = preview
                metadataPreviewStageName = selected.lastPathComponent
            } catch {
                metadataActivationMessage = "本机验证取消或失败，未读取或修改数据。"
            }
            metadataPreviewLoading = false
        }
    }

    /// The backend is stopped only after the owner has reviewed the same
    /// manifest whose digest was returned by the preview helper.
    func activateRestoredMetadata() {
        guard state == .online, !activatingMetadata, backupStatus?.running != true,
              let fullPath = backupStatus?.restoredMetadata,
              let preview = metadataPreview, preview.isReady,
              let previewStageName = metadataPreviewStageName else { return }
        let selected = URL(fileURLWithPath: fullPath).standardizedFileURL
        guard selected.lastPathComponent == previewStageName,
              selected.lastPathComponent.hasPrefix("LightIsle-RestoredMetadata-"),
              let dataDir = Self.privateMetadataDirectory,
              selected.deletingLastPathComponent().standardizedFileURL == URL(fileURLWithPath: dataDir).standardizedFileURL else {
            metadataActivationMessage = "恢复目录已变化，请重新检查影响预览。"
            metadataPreview = nil
            metadataPreviewStageName = nil
            return
        }

        let alert = NSAlert()
        alert.messageText = "应用已恢复的数据库？"
        alert.informativeText = Self.metadataPreviewConfirmation(preview) +
            "\n\nMac 所有者验证后会停止 Go Core 并替换数据库。原数据库会作为可回退版本保留；共享原片不会覆盖，原片与数据库快照不保证来自同一时间点。图库与影视索引可在恢复后手动重扫。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "验证身份并应用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        activatingMetadata = true
        metadataActivationMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = LAContext()
            var policyError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
                metadataActivationMessage = "无法验证本机所有者，未修改任何数据。"
                activatingMetadata = false
                return
            }
            do {
                let approved = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "验证 Mac 所有者身份，以离线恢复轻屿数据库"
                )
                guard approved else { throw NSError(domain: "LightIsle", code: 1) }
                await stop()
                metadataActivationMessage = await Self.runOfflineRecovery(
                    operation: "activate",
                    dataDir: dataDir,
                    stage: selected.lastPathComponent,
                    confirmation: "I_UNDERSTAND_OFFLINE_METADATA_REPLACEMENT",
                    expectedManifestSHA256: preview.manifestSHA256
                )
                metadataPreview = nil
                metadataPreviewStageName = nil
                launch()
            } catch {
                metadataActivationMessage = "用户验证取消或失败，现有数据库保持原样。"
            }
            activatingMetadata = false
        }
    }

    private static func metadataPreviewConfirmation(_ preview: NASMetadataRecoveryPreview) -> String {
        let labels = metadataPreviewLabels
        return labels.map { item in
            let count = preview.counts[item.0]
            return "\(item.1)：当前 \(displayPreviewCount(count?.current)) → 恢复后 \(displayPreviewCount(count?.staged))"
        }.joined(separator: "\n")
    }

    private static var metadataPreviewLabels: [(String, String)] {
        [
            ("accounts.users", "账号"),
            ("accounts.fileGrants", "旧目录授权"),
            ("accounts.rootFileGrants", "共享根授权"),
            ("accounts.rootFileShares", "临时目录分享"),
            ("gallery.privateAlbums", "私人相册"),
            ("gallery.privateAlbumItems", "私人相册项目"),
            ("gallery.favorites", "收藏"),
            ("gallery.manualAlbums", "手工相册"),
            ("gallery.indexedAssets", "图库索引项目"),
            ("cinema.manualTitles", "手工影视标题"),
            ("cinema.indexedFilms", "影视索引项目"),
            ("tasks.journal", "任务摘要"),
            ("tasks.history", "任务历史")
        ]
    }

    private static func displayPreviewCount(_ count: Int64?) -> String {
        count.map { $0.formatted() } ?? "未知"
    }

    private static func runMetadataPreview(dataDir: String, stage: String) async -> NASMetadataRecoveryPreview {
        let failure = NASMetadataRecoveryPreview(schemaVersion: 1, operation: "preview", status: "failed",
            verified: false, manifestSHA256: "", counts: [:], warnings: [],
            error: NASMetadataPreviewError(code: "preview_unavailable", message: "无法验证恢复预览，当前数据库未修改。"))
        guard let binary = Bundle.main.resourceURL?.appendingPathComponent("core/lightisle-recovery"),
              FileManager.default.isExecutableFile(atPath: binary.path) else { return failure }
        let result = await OfflineRecoveryRunner.run(binary: binary, arguments: [
            "--data-dir", dataDir, "--operation", "preview", "--stage", stage,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)
        ], timeout: 40, outputLimit: 64 * 1024)
        guard !result.timedOut, !result.truncated, result.exitCode == 0,
              let response = try? JSONDecoder().decode(NASMetadataRecoveryPreview.self, from: result.output) else {
            return failure
        }
        return response
    }

    func recoverInterruptedMetadata() {
        guard !activatingMetadata, state != .online else { return }
        let alert = NSAlert()
        alert.messageText = "修复中断的离线数据库恢复？"
        alert.informativeText = "仅用于上次恢复过程中断的情况。将恢复之前的数据库，并把中途生成的新文件保存在隔离目录。需要 Mac 所有者认证。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "验证并回滚")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        activatingMetadata = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = LAContext()
            do {
                let approved = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "验证 Mac 所有者身份以修复中断的数据库恢复"
                )
                guard approved else { throw NSError(domain: "LightIsle", code: 1) }
                await stop()
                let root = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
                let dataDir = root?.appendingPathComponent("LightIsle").path ?? ""
                guard !dataDir.isEmpty else {
                    metadataActivationMessage = "无法确定应用数据库目录，已停止操作。"
                    activatingMetadata = false
                    return
                }
                metadataActivationMessage = await Self.runOfflineRecovery(
                    operation: "recover",
                    dataDir: dataDir,
                    stage: "",
                    confirmation: "RESTORE_PREVIOUS_METADATA"
                )
                launch()
            } catch {
                metadataActivationMessage = "本机验证取消或失败，未修改数据。"
            }
            activatingMetadata = false
        }
    }

    private static func runOfflineRecovery(operation: String, dataDir: String, stage: String, confirmation: String,
                                           expectedManifestSHA256: String? = nil) async -> String {
        guard let binary = Bundle.main.resourceURL?.appendingPathComponent("core/lightisle-recovery"),
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            return "内置离线恢复程序缺失，数据未更改。"
        }
        var arguments = [
            "--data-dir", dataDir, "--operation", operation, "--stage", stage,
            "--confirm", confirmation, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)
        ]
        if let expectedManifestSHA256 {
            arguments += ["--expected-manifest-sha256", expectedManifestSHA256]
        }
        let result = await OfflineRecoveryRunner.run(binary: binary, arguments: arguments)
        let text = String(decoding: result.output.prefix(4096), as: UTF8.self)
        if result.timedOut {
            return "离线操作超过等待时间，已停止工具。请检查是否需要修复中断的恢复。"
        }
        if result.exitCode == 0 {
            if operation == "activate" {
                return "数据库已恢复，之前版本已保留为可回退记录。共享文件未覆盖；请按需重新扫描图库与影视索引。"
            }
            return "离线数据库操作成功：\(text)"
        }
        if operation == "activate" && text.contains("staged_metadata_changed_since_preview") {
            return "恢复目录在预览后发生变化，未应用数据库。请重新检查恢复影响。"
        }
        if operation == "activate" {
            return "离线数据库恢复未能完成；当前或回退版本均会保留。请检查恢复状态后重试。"
        }
        return "离线数据库操作未成功：\(text)。如提示恢复中断，请选择“修复中断的恢复”。"
    }

    private static var privateMetadataDirectory: String? {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false))?
            .appendingPathComponent("LightIsle").path
    }

    func refreshMetadataRollbacks() {
        guard !activatingMetadata, !metadataRollbacksLoading,
              let dataDir = Self.privateMetadataDirectory,
              let binary = Bundle.main.resourceURL?.appendingPathComponent("core/lightisle-recovery") else { return }
        metadataRollbacksLoading = true
        metadataRollbackError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await OfflineRecoveryRunner.run(binary: binary, arguments: [
                "--data-dir", dataDir, "--operation", "list", "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)
            ], timeout: 30)
            if result.exitCode == 0, !result.truncated, !result.timedOut,
               let inventory = try? JSONDecoder().decode(NASMetadataRollbackInventory.self, from: result.output),
               inventory.schemaVersion == 1, inventory.operation == "list" {
                metadataRollbacks = inventory
            } else {
                metadataRollbackError = result.timedOut ? "读取回退版本超时，请重试。" : "无法读取可验证的回退版本，请检查本机恢复日志后重试。"
            }
            metadataRollbacksLoading = false
        }
    }

    func rollbackMetadata(_ transaction: NASMetadataRollbackTransaction) {
        guard state != .starting, state != .stopping, !activatingMetadata, !metadataRollbacksLoading,
              backupStatus?.running != true, transaction.canRollback,
              metadataRollbacks?.transactions.contains(where: { $0.id == transaction.id && $0.canRollback }) == true,
              let dataDir = Self.privateMetadataDirectory,
              let binary = Bundle.main.resourceURL?.appendingPathComponent("core/lightisle-recovery") else { return }
        let alert = NSAlert()
        alert.messageText = "回退到这次恢复之前的账号与配置？"
        alert.informativeText = "将验证 Mac 所有者身份并停止服务。当前数据库及之后的变更会保存在独立目录，再恢复经校验的上一版本；共享文件不会被替换。所有 Web 会话需重新登录。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "验证身份并回退")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        activatingMetadata = true
        metadataActivationMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let context = LAContext()
                let approved = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                    localizedReason: "验证 Mac 所有者身份，以离线回退轻屿账号与配置")
                guard approved else { throw NSError(domain: "LightIsle", code: 1) }
                await stop()
                let result = await OfflineRecoveryRunner.run(binary: binary, arguments: [
                    "--data-dir", dataDir, "--operation", "rollback", "--transaction-id", transaction.id,
                    "--confirm", "ROLLBACK_OFFLINE_METADATA", "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)
                ])
                if result.exitCode == 0, !result.truncated, !result.timedOut,
                   let response = try? JSONDecoder().decode(NASMetadataRollbackResult.self, from: result.output),
                   response.schemaVersion == 1, response.status == "rolled_back" {
                    metadataActivationMessage = "已回退账号与配置。回退前的数据保存在：\(response.preservedCurrent ?? "私有回退目录")。请重新登录 Web。"
                    AdminCredentialVault.remove()
                    unlockedAdminCredentials = nil
                    pendingAdminCredentials = nil
                } else {
                    metadataActivationMessage = "回退未能完成；数据版本将保留。如服务提示恢复中断，请使用“修复中断的恢复”。"
                }
                metadataRollbacks = nil
                launch()
            } catch {
                metadataActivationMessage = "本机验证取消或失败，未开始回退。"
            }
            activatingMetadata = false
        }
    }

}

struct NASMetadataRollbackTransaction: Decodable, Identifiable {
    let id: String
    let state: String
    let canRollback: Bool
    let reason: String?
    let activatedAt: Int64
    let fileCount: Int
}

struct NASMetadataRollbackInventory: Decodable {
    let schemaVersion: Int
    let operation: String
    let transactions: [NASMetadataRollbackTransaction]
    let truncated: Bool
}

private struct NASMetadataRollbackResult: Decodable {
    let schemaVersion: Int
    let status: String
    let preservedCurrent: String?
}

struct HostVolume: Decodable, Identifiable {
    let name: String
    let mount: String
    let device: String
    let filesystem: String
    let total: UInt64
    let free: UInt64
    let readOnly: Bool
    var id: String { mount }
}
struct NASBackupSchedule: Decodable {
    let enabled: Bool
    let everyHours: Int
    let destination: String?
    let lastAttempt: Int64
    let nextRun: Int64
    let lastError: String?
    let planID: String?
    let retentionCount: Int?
    let destinationVolumeUUID: String?
    let destinationDirectoryID: String?
    let destinationIdentityStatus: String?
}

struct NASBackupStatus: Decodable {
    let running: Bool
    let operation: String
    let files: Int
    let bytes: Int64
    let lastError: String?
    let lastSnapshot: String?
    let restoredMetadata: String?
    let lastDone: Int64?
    let retentionError: String?
    let retentionRemoved: Int?
}

struct NASBackupSnapshot: Decodable, Identifiable {
    let name: String
    let path: String
    let version: String
    let createdAt: Int64
    let sizeBytes: Int64
    let integrity: String
    let integrityDetail: String?
    var id: String { path }
}

struct NASBackupInventory: Decodable {
    let destination: String
    let snapshots: [NASBackupSnapshot]
    let truncated: Bool
    let scannedEntries: Int
}

struct HostProcess: Decodable, Identifiable {
    let pid: Int
    let name: String
    let cpuPercent: Double?
    let rssBytes: UInt64?
    var id: Int { pid }
}

struct HostMetrics: Decodable {
    let hostname: String
    let architecture: String
    let cpuCount: Int
    let cpuPercent: Double?
    let memoryTotal: UInt64
    let memoryUsed: UInt64
    let diskTotal: UInt64
    let diskFree: UInt64
    let volumes: [HostVolume]?
    let networkDownBps: Double?
    let networkUpBps: Double?
    let corePid: Int?
    let coreRssBytes: UInt64?
    let processes: [HostProcess]?
    let processesAvailable: Bool?
}

struct MetricHistoryPoint: Identifiable {
    let id = UUID()
    let time: Date
    let cpu: Double
    let memory: Double
    let download: Double
    let upload: Double
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let rootManagement = NativeRootsModel(enabled: ProcessInfo.processInfo.environment["LIGHTISLE_MULTI_ROOT_PREVIEW"] == "1")

    @Published private(set) var state: CoreState = .offline {
        didSet {
            updateSleepPolicy()
            updateBonjour()
            if case .error = state {
                notifyImportantEvent("core-failure", title: "LightIsle 服务异常", message: "NAS 核心未能正常运行，请在 Mac 上打开轻屿检查。")
            } else if state == .online {
                nativeAlertDelivery.clear(key: "core-failure")
            }
        }
    }
    @Published var selectedSidebarPage: SidebarPage = .overview
    @Published private(set) var reindexRequestMessage: String?

    func rebuildMediaIndexes() {
        guard state == .online, !activatingMetadata, backupStatus?.running != true else {
            reindexRequestMessage = "数据库恢复或备份期间不能重新扫描。"
            return
        }
        do {
            try inputPipe?.fileHandleForWriting.write(contentsOf: Data("index scan\n".utf8))
            reindexRequestMessage = "已请求后台扫描照片和影视目录。此操作不恢复已丢失的原始文件，不删除私人相册配置。"
        } catch {
            reindexRequestMessage = "无法请求扫描，请检查 Core 服务状态。"
        }
    }
    @Published private(set) var keepAwakeWhileServing = UserDefaults.standard.bool(forKey: "lightisle.keepAwakeWhileServing")
    @Published private(set) var loginItemError: String?
    private func checkLowDiskSpace(_ volumes: [HostVolume]) {
        guard nativeAlertsEnabled else { return }
        for volume in volumes where !volume.readOnly && volume.total > 0 {
            let low = volume.free < 5 * 1024 * 1024 * 1024 ||
                Double(volume.free) / Double(volume.total) < 0.05
            let key = "disk-space:" + volume.mount
            if low {
                notifyImportantEvent(key, title: "轻屿磁盘空间不足",
                                     message: "有存储卷剩余空间低于 5 GiB 或 5%，请打开数据与存储查看。")
            } else {
                nativeAlertDelivery.clear(key: key)
            }
        }
    }
    private var sleepActivity: NSObjectProtocol?
    @Published private(set) var nativeAlertsEnabled = UserDefaults.standard.bool(forKey: "lightisle.nativeAlertsEnabled")
    @Published private(set) var nativeAlertError: String?
    private var alertAuthorizationPending = false
    private let nativeAlertDelivery = NativeAlertDelivery()
    private var lastAlertPollAt = Date.distantPast
    private var lastActiveAlertCodes = Set<String>()

    private func presentCoreAlerts(_ alerts: [CorePersistentAlert]) {
        let codes = Set(alerts.filter(\.active).map(\.code))
        for recovered in lastActiveAlertCodes.subtracting(codes) {
            nativeAlertDelivery.clear(key: alertDeliveryKey(recovered))
        }
        lastActiveAlertCodes = codes
        guard nativeAlertsEnabled else { return }
        for alert in alerts where alert.active && !alert.acknowledged {
            guard alert.code.count <= 80, alert.message.utf8.count <= 512,
                  ["storage_offline", "storage_low_space", "backup_failed",
                   "gallery_scan_failed", "cinema_scan_failed"].contains(alert.code) else { continue }
            // Direct IPC events and persisted task alerts share a rate-limit
            // identity; the same failure must not trigger two Mac banners.
            if alert.code == "storage_low_space" { continue }
            nativeAlertDelivery.deliver(key: alertDeliveryKey(alert.code),
                title: alert.severity == "critical" ? "轻屿 NAS 重要告警" : "轻屿 NAS 运行提醒",
                description: alert.message)
        }
    }

    private func alertDeliveryKey(_ code: String) -> String {
        if code == "storage_offline" { return "volume-unavailable" }
        if code == "backup_failed" { return "backup-failure" }
        return "journal:" + code
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
            let allowed = await nativeAlertDelivery.requestPermission()
            self.alertAuthorizationPending = false
            self.nativeAlertsEnabled = allowed
            self.nativeAlertError = allowed ? nil : "macOS 未授权轻屿发送通知，请在系统设置 → 通知中检查。"
            UserDefaults.standard.set(allowed, forKey: "lightisle.nativeAlertsEnabled")
        }
    }

    private func notifyImportantEvent(_ key: String, title: String, message: String) {
        guard nativeAlertsEnabled else { return }
        nativeAlertDelivery.deliver(key: key, title: title, description: message)
    }

    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

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
        updateSleepPolicy()
    }

    private func updateSleepPolicy() {
        let shouldPreventIdleSleep = keepAwakeWhileServing && state == .online
        if shouldPreventIdleSleep && sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "LightIsle is serving the personal NAS"
            )
        } else if !shouldPreventIdleSleep, let existing = sleepActivity {
            ProcessInfo.processInfo.endActivity(existing)
            sleepActivity = nil
        }
    }
    @Published private(set) var endpoint: URL?
    @Published private(set) var details: String = "LightIsle 应用负责管理内置服务的完整生命周期。"
    @Published private(set) var remoteAddress: String? {
        didSet { updateBonjour() }
    }
    @Published private(set) var bonjourStatus = "未广播（局域网 HTTPS 未开启）"
    private lazy var bonjourPublisher: BonjourPublisher = {
        let publisher = BonjourPublisher()
        publisher.onStatusChange = { [weak self] status in self?.bonjourStatus = status }
        return publisher
    }()

    private func updateBonjour() {
        guard state == .online, let address = remoteAddress,
              let url = URL(string: address), url.scheme == "https",
              let port = url.port, (1...65535).contains(port) else {
            bonjourPublisher.stop()
            return
        }
        bonjourPublisher.update(httpsPort: port)
    }
    @Published private(set) var remoteFingerprint: String?
    @Published private(set) var remoteError: String?
    @Published private(set) var sharedFolderName: String = "SharedFiles"
    @Published private(set) var sharedFolderPath: String? {
        didSet {
            if oldValue != sharedFolderPath {
                invalidateTimeMachineDiagnostics()
            }
        }
    }
    @Published private(set) var sharedFolderError: String?
    @Published private(set) var offlineSharedFolderPath: String?
    @Published private(set) var offlineCleanupPending = false
    @Published private(set) var offlineCleanupMessage: String?
    @Published private(set) var storageSelectionMessage: String?
    @Published private(set) var storageSelectionPending = false
    private var pendingStorageTarget: String?
    private var previousStorageRoot: String?
    private var storageSelectionDeadline: Task<Void, Never>?

    private func clearPendingStorageSelection() {
        storageSelectionDeadline?.cancel()
        storageSelectionDeadline = nil
        storageSelectionPending = false
        pendingStorageTarget = nil
        previousStorageRoot = nil
    }
    @Published private(set) var exportRunning = false
    @Published private(set) var exportMessage: String?
    @Published private(set) var transferHistory: [FileTransferReceipt] = []
    private var activeExportMode = "copy"
    @Published private(set) var isConfigured: Bool?
    @Published private(set) var initializationError: String?
    @Published private(set) var initializing = false
    @Published private(set) var metrics: HostMetrics?
    @Published private(set) var metricHistory: [MetricHistoryPoint] = []
    @Published private(set) var backupStatus: NASBackupStatus?
    @Published private(set) var backupError: String?
    @Published private(set) var backupInventory: NASBackupInventory?
    @Published private(set) var backupInventoryLoading = false
    @Published private(set) var activatingMetadata = false
    @Published private(set) var metadataActivationMessage: String?
    @Published private(set) var metadataPreview: NASMetadataRecoveryPreview?
    @Published private(set) var metadataPreviewStageName: String?
    @Published private(set) var metadataPreviewLoading = false
    @Published private(set) var metadataRollbacks: NASMetadataRollbackInventory?
    @Published private(set) var metadataRollbacksLoading = false
    @Published private(set) var metadataRollbackError: String?
    @Published private(set) var upgradePreflight: NativeUpgradePreflightReport?
    @Published private(set) var upgradePreflightChecking = false
    private var upgradePreflightRequest: UUID?

    func checkUpgradePreflight() {
        guard !upgradePreflightChecking,
              let directory = Self.privateMetadataDirectory else { return }
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
    @Published private(set) var smbListening: Bool?
    @Published private(set) var timeMachineDiagnostics: TimeMachineDiagnostics?
    @Published private(set) var timeMachineChecking = false
    private var timeMachineDiagnosticsGeneration: UInt64 = 0

    private func invalidateTimeMachineDiagnostics() {
        timeMachineDiagnosticsGeneration &+= 1
        timeMachineDiagnostics = nil
        timeMachineChecking = false
    }
    @Published private(set) var backupSchedule: NASBackupSchedule?
    @Published private(set) var portError: String?
    @Published private(set) var thumbnailCacheError: String?
    @Published private(set) var webOpenError: String?
    @Published private(set) var vaultMessage: String?
    @Published private(set) var unlockedAdminCredentials: AdminCredentials?
    @Published private(set) var verifyingAdmin = false
    @Published private(set) var resettingAdmin = false
    @Published private(set) var resetAdminMessage: String?
    @Published private(set) var firstAdminUsername: String?
    private var pendingAdminCredentials: AdminCredentials?
    private var directoryWatcher: DirectoryChangeWatcher?
    private var scanRefreshTask: Task<Void, Never>?
    private var lastAutomaticScanRequest = Date.distantPast
    private var pendingMediaDirs = Set<String>()
    private var pendingFullMediaScan = false

    private func cancelScheduledIndexRefresh() {
        scanRefreshTask?.cancel()
        scanRefreshTask = nil
        pendingMediaDirs.removeAll()
        pendingFullMediaScan = false
    }

    private func scheduleIndexRefresh(paths: [String]?, needsFull: Bool) {
        guard state == .online, let watchedPath = sharedFolderPath else { return }
        let changedDirectories = MediaScanScope.directories(for: paths, under: watchedPath)
        if needsFull || changedDirectories == nil {
            pendingFullMediaScan = true
        } else {
            pendingMediaDirs.formUnion(changedDirectories ?? [])
            if pendingMediaDirs.count > 32 {
                pendingFullMediaScan = true
            }
        }
        guard scanRefreshTask == nil else { return }
        // FSEvents may deliver thousands of callbacks during one file copy.
        // Collapse them into a single scan request, at most once per minute.
        let elapsed = Date().timeIntervalSince(lastAutomaticScanRequest)
        let delay = max(2.0, 60.0 - elapsed)
        scanRefreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self else { return }
            self.scanRefreshTask = nil
            guard !Task.isCancelled, self.state == .online,
                  self.sharedFolderPath == watchedPath else { return }
            self.lastAutomaticScanRequest = Date()
            let dirs = Array(self.pendingMediaDirs).sorted()
            let full = self.pendingFullMediaScan || dirs.isEmpty || dirs.contains(".")
            self.pendingMediaDirs.removeAll()
            self.pendingFullMediaScan = false
            if !full,
               let encoded = try? JSONSerialization.data(withJSONObject: dirs).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: ""),
               encoded.utf8.count <= 11000 {
                try? self.inputPipe?.fileHandleForWriting.write(contentsOf: Data(("index dirs " + encoded + "\n").utf8))
            } else {
                try? self.inputPipe?.fileHandleForWriting.write(contentsOf: Data("index scan\n".utf8))
            }
        }
    }

    static let defaultLocalPort = 16666
    var preferredLocalPort: Int {
        let value = UserDefaults.standard.integer(forKey: "lightisle.localPort")
        return (1024...65535).contains(value) ? value : Self.defaultLocalPort
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

    static let thumbnailCacheOptions: [Int] = [256, 512, 1024, 2048, 4096, 8192]
    static let defaultThumbnailCacheMiB = 1024

    var preferredThumbnailCacheMiB: Int {
        let value = UserDefaults.standard.integer(forKey: "lightisle.thumbnailCacheMiB")
        return Self.thumbnailCacheOptions.contains(value) ? value : Self.defaultThumbnailCacheMiB
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

    private var core: Process?
    // Detached from the window lifecycle: closing the last window must not
    // suspend NAS metrics, offline-volume alerts or persisted alert polling.
    private var servicePollingTask: Task<Void, Never>?
    private var startupDeadlineTask: Task<Void, Never>?
    private static let coreStartupDeadlineSeconds: Double = 20
    private func cancelStartupDeadline() {
        startupDeadlineTask?.cancel()
        startupDeadlineTask = nil
    }

    private func startStartupDeadline(generation: UUID) {
        cancelStartupDeadline()
        startupDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.coreStartupDeadlineSeconds))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.coreGeneration == generation,
                  self.state == .starting else { return }
            // Do not keep a partially initialized backend running. Retain
            // the normal parent-owned shutdown and require an explicit retry.
            await self.stop()
            guard self.core == nil, self.state == .offline else { return }
            self.state = .error("Go Core 启动超时（20 秒内未报告就绪）")
            self.details = "已停止未就绪的后端。请检查数据库恢复状态、端口占用和本机错误日志，再手动重试。"
        }
    }
    private func beginServicePolling() {
        servicePollingTask?.cancel()
        servicePollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshMetrics()
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    break
                }
            }
        }
    }
    private func endServicePolling() {
        servicePollingTask?.cancel()
        servicePollingTask = nil
    }
    private var inputPipe: Pipe?
    private var coreGeneration: UUID?
    private var outputPipe: Pipe?
    private var coreOutputFramer = CoreLineFramer()
    private var stopping = false
    private var lastShareStatusPollAt = Date.distantPast

    var hasChildProcess: Bool { core != nil }
    var isRemoteEnabled: Bool { remoteAddress != nil }

    func saveAdministratorWithTouchID(username: String, password: String) {
        guard state == .online, isConfigured == true, !verifyingAdmin else { return }
        guard AdminCredentialVault.available() else {
            vaultMessage = "此 Mac 尚未启用 Touch ID，请先在系统设置中录入指纹。"
            return
        }
        guard !username.isEmpty, !password.isEmpty else {
            vaultMessage = "请先输入已有管理员账号和正确密码。"
            return
        }
        let credentials = AdminCredentials(username: username, password: password)
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        pendingAdminCredentials = credentials
        verifyingAdmin = true
        vaultMessage = nil
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data(("admin verify " + payload + "\n").utf8))
    }

    func unlockAdministratorWithTouchID() {
        vaultMessage = nil
        unlockedAdminCredentials = nil
        Task {
            do {
                let result = try await Task.detached { try AdminCredentialVault.unlock() }.value
                unlockedAdminCredentials = result
                vaultMessage = "Touch ID 已解锁，凭据将在 30 秒后自动隐藏。"
                try? await Task.sleep(for: .seconds(30))
                unlockedAdminCredentials = nil
            } catch {
                vaultMessage = error.localizedDescription
            }
        }
    }

    func removeSavedAdministrator() {
        AdminCredentialVault.remove()
        pendingAdminCredentials = nil
        unlockedAdminCredentials = nil
        vaultMessage = "已删除本机钥匙串记录，不影响管理员账号。"
    }

    func resetAdministratorPassword(newPassword: String) {
        guard state == .online, isConfigured == true, !resettingAdmin else { return }
        guard newPassword.utf8.count >= 12, newPassword.utf8.count <= 256,
              newPassword.trimmingCharacters(in: .whitespacesAndNewlines) == newPassword else {
            resetAdminMessage = "新密码至少 12 位、最多 256 字节，且不能以空格开头或结尾。"
            return
        }
        resettingAdmin = true
        resetAdminMessage = nil
        Task {
            let context = LAContext()
            var policyError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
                resetAdminMessage = "macOS 无法执行设备所有者验证，请检查系统登录密码或 Touch ID 设置。"
                resettingAdmin = false
                return
            }
            do {
                let approved = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "验证 Mac 登录密码或 Touch ID，以重置轻屿管理员密码"
                )
                guard approved, state == .online, let pipe = inputPipe else {
                    resettingAdmin = false
                    resetAdminMessage = "认证已取消或本地服务不可用。"
                    return
                }
                let payload = try JSONSerialization.data(withJSONObject: ["password": newPassword])
                let encoded = payload.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
                try pipe.fileHandleForWriting.write(contentsOf: Data(("admin reset " + encoded + "\n").utf8))
            } catch {
                resettingAdmin = false
                resetAdminMessage = "设备验证取消或失败，管理员密码未更改。"
            }
        }
    }

    func refreshMetrics() {
        guard state == .online else { return }
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("stats\n".utf8))
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("backup status\nbackup schedule status\nsmb status\n".utf8))
        if Date().timeIntervalSince(lastAlertPollAt) >= 60 {
            lastAlertPollAt = Date()
            try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("alerts status\n".utf8))
        }
        if Date().timeIntervalSince(lastShareStatusPollAt) >= 30 {
            lastShareStatusPollAt = Date()
            try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("share status\n".utf8))
        }
    }

    func refreshTimeMachineDiagnostics() {
        guard !timeMachineChecking else { return }
        timeMachineChecking = true
        let currentRoot = sharedFolderPath
        let generation = timeMachineDiagnosticsGeneration
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                TimeMachineDiagnostics.read(sharedPath: currentRoot)
            }.value
            guard let self else { return }
            // Never publish the backup result for an old/remounted NAS root.
            guard self.timeMachineDiagnosticsGeneration == generation,
                  self.sharedFolderPath == currentRoot else { return }
            self.timeMachineDiagnostics = result
            self.timeMachineChecking = false
        }
    }

    func openTimeMachineSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
    func configureBackupSchedule(hours: Int, retentionCount: Int = 0) {
        guard state == .online, !activatingMetadata, hours == 24 || hours == 168, (0...30).contains(retentionCount) else { return }
        if retentionCount > 0 {
            let alert = NSAlert()
            alert.messageText = "仅保留最近 \(retentionCount) 个计划快照？"
            alert.informativeText = "每次新计划备份完整成功后，才会清理同一计划、同一共享目录的旧快照。手动备份、旧版快照和其他计划的快照会保留；无法安全确认时停止清理。此设置不会立即删除快照。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "继续选择备份目录")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择自动备份目录"
        panel.message = "定时备份只在 LightIsle.app 运行时执行。将记录所选磁盘和文件夹的身份；缺盘或同路径换盘时会停止派发，需要重新选择确认。"
        guard panel.runModal() == .OK, let folder = panel.url?.path else { return }
        sendBackupCommand("backup schedule set \(hours) \(retentionCount)", path: folder)
    }
    func disableBackupSchedule() {
        guard state == .online else { return }
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("backup schedule off\n".utf8))
    }

    func startBackup() {
        guard state == .online, !activatingMetadata, backupStatus?.running != true else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "备份到此文件夹"
        panel.message = "在所选目录下创建新的 LightIsle-Backup 快照。请选择与共享目录不同的磁盘或独立文件夹。操作不会删除原文件。"
        guard panel.runModal() == .OK, let chosen = panel.url?.path else { return }
        sendBackupCommand("backup start", path: chosen)
    }

    func browseBackupInventory() {
        guard state == .online, !backupInventoryLoading else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "查看此目录的备份"
        panel.message = "选择存放 LightIsle-Backup 快照的目录。这里只读取清单，不删除快照；恢复时仍会逐项校验 SHA-256。"
        guard panel.runModal() == .OK, let chosen = panel.url?.path else { return }
        backupInventory = nil
        backupInventoryLoading = true
        sendBackupCommand("backup inventory", path: chosen)
    }

    func cancelBackup() {
        guard state == .online, backupStatus?.running == true else { return }
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("backup cancel\n".utf8))
    }

    func restoreBackup() {
        guard state == .online, !activatingMetadata, backupStatus?.running != true else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "从此备份恢复"
        panel.message = "选择 LightIsle-Backup-... 文件夹。将校验 SHA-256，并恢复到共享目录中新的 LightIsle-Restored-... 文件夹，不会覆盖现有文件。"
        guard panel.runModal() == .OK, let chosen = panel.url?.path else { return }
        sendBackupCommand("backup restore", path: chosen)
    }

    private func sendBackupCommand(_ operation: String, path: String) {
        let encoded = Data(path.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        backupError = nil
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data((operation + " " + encoded + "\n").utf8))
    }

    func initializeAdministrator(username: String, password: String) {
        guard isConfigured == false, !initializing, state == .online else { return }
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^[A-Za-z0-9_.-]{3,32}$", options: .regularExpression) != nil,
              password.utf8.count >= 12, password.utf8.count <= 256 else {
            initializationError = "用户名需为 3–32 位英数字或 . _ -；密码至少 12 位。"
            return
        }
        let payload = ["username": trimmed, "password": password]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            initializationError = "初始化参数无效"
            return
        }
        let command = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        initializationError = nil
        initializing = true
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data(("admin init " + command + "\n").utf8))
    }

    func openUserWeb(page: String? = nil) {
        guard let base = endpoint, state == .online else {
            webOpenError = "轻屿核心服务尚未就绪，请检查运行状态。"
            return
        }
        webOpenError = nil
        let target: URL
        if let page = page, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "page", value: page)]
            target = components.url ?? base
        } else {
            target = base
        }
        Task {
            do {
                var request = URLRequest(url: base)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 5
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      String(decoding: data.prefix(4096), as: UTF8.self).contains("LightIsle"),
                      endpoint == base else {
                    webOpenError = "无法加载 Web 空间，请确认轻屿核心已正常启动。"
                    return
                }
                NSWorkspace.shared.open(target)
            } catch {
                webOpenError = "本机 Web 服务暂不可用，请确认端口未被占用。"
            }
        }
    }

    func openActivityMonitor() {
        let activityMonitor = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: activityMonitor, configuration: NSWorkspace.OpenConfiguration())
    }

    func setRemoteEnabled(_ enabled: Bool) {
        guard state == .online, let pipe = inputPipe else { return }
        remoteError = nil
        let command = enabled ? "remote on\n" : "remote off\n"
        try? pipe.fileHandleForWriting.write(contentsOf: Data(command.utf8))
    }

    var canChangeSharedStorage: Bool {
        state == .online && !rootManagement.enabled && !storageSelectionPending &&
            !offlineCleanupPending && !exportRunning && !activatingMetadata && backupStatus?.running != true
    }

    @Published private(set) var managedDisks: [ManagedDisk] = []
    @Published private(set) var diskManagementError: String?
    @Published private(set) var diskOperationPending = false
    private var diskOperationDeadline: Task<Void, Never>?

    func refreshManagedDisks() {
        guard state == .online, !diskOperationPending else { return }
        diskManagementError = nil
        do {
            try inputPipe?.fileHandleForWriting.write(contentsOf: Data("disk list\n".utf8))
        } catch {
            diskManagementError = "无法读取磁盘状态：\(error.localizedDescription)"
        }
    }

    func manageDisk(_ disk: ManagedDisk, action: String) {
        guard state == .online, !diskOperationPending, disk.external,
              disk.identity.count == 64,
              managedDisks.contains(where: { $0.id == disk.id && $0.identity == disk.identity }),
              ["rename", "mount", "eject"].contains(action) else { return }
        let names = ["rename": "重命名", "mount": "挂载", "eject": "安全弹出"]
        let alert = NSAlert()
        alert.alertStyle = action == "eject" ? .warning : .informational
        alert.messageText = "\(names[action] ?? action)「\(disk.name)」？"
        alert.informativeText = """
        设备：\(disk.id) · \(disk.filesystem)
        \(disk.mount.isEmpty ? "未挂载" : disk.mount)

        操作会由 Mac 系统执行。NAS 正在使用或备份中的硬盘会被 Core 拒绝操作；不执行强制卸载，数据写入尚未结束时不应拔掉电源或数据线。
        """
        let field = NSTextField(string: disk.name)
        if action == "rename" {
            field.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
            alert.accessoryView = field
        }
        alert.addButton(withTitle: names[action] ?? "确认")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = action == "rename" ? field.stringValue : ""
        let payload: [String: String] = ["action": action, "id": disk.id, "identity": disk.identity, "name": name]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let pipe = inputPipe?.fileHandleForWriting else { return }
        diskOperationPending = true
        diskManagementError = nil
        do {
            let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            try pipe.write(contentsOf: Data(("disk action " + encoded + "\n").utf8))
            diskOperationDeadline?.cancel()
            diskOperationDeadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                guard let self, self.diskOperationPending else { return }
                self.diskOperationPending = false
                self.diskManagementError = "未及时收到磁盘操作结果，请刷新磁盘状态后确认实际结果。"
            }
        } catch {
            diskOperationPending = false
            diskManagementError = "发送操作失败：\(error.localizedDescription)"
        }
    }

    var canForgetOfflineShare: Bool {
        canChangeSharedStorage && sharedFolderPath == nil &&
            offlineSharedFolderPath != nil
    }

    func keepOfflineShare() {
        guard let path = offlineSharedFolderPath else { return }
        offlineCleanupMessage = "已保留原磁盘绑定和媒体记录（\(path)）。重新接上原磁盘后点击「重新连接」。"
    }

    func forgetOfflineShare() {
        guard canForgetOfflineShare, let oldPath = offlineSharedFolderPath else { return }
        let first = NSAlert()
        first.alertStyle = .critical
        first.messageText = "清除离线磁盘的 LightIsle 记录？"
        first.informativeText = """
        原共享路径：\(oldPath)

        只有本机应用的磁盘绑定和媒体记录会被清理，旧磁盘上的真实照片、影片、文件不会被访问或删除。此操作会丢失该目录在本地的照片收藏、相册关系、观看进度，以及旧目录的成员文件授权和下载分享链接；管理员账号不会删除。NAS 存储将切换到 Mac 本机默认目录，旧磁盘日后重连需重新授权。建议先独立备份 LightIsle 的元数据目录。
        """
        first.addButton(withTitle: "继续核对")
        first.addButton(withTitle: "取消，保留记录")
        guard first.runModal() == .alertFirstButtonReturn else { return }

        let second = NSAlert()
        second.alertStyle = .critical
        second.messageText = "最后确认：请输入「清理」"
        second.informativeText = "确认只移除离线磁盘的本地记录。真实外置盘文件不受影响。"
        let confirmation = NSTextField(string: "")
        confirmation.placeholderString = "输入 清理"
        confirmation.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        second.accessoryView = confirmation
        second.addButton(withTitle: "清理离线记录")
        second.addButton(withTitle: "取消")
        guard second.runModal() == .alertFirstButtonReturn,
              confirmation.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == "清理" else { return }
        guard canForgetOfflineShare, offlineSharedFolderPath == oldPath,
              let pipe = inputPipe?.fileHandleForWriting else { return }
        offlineCleanupPending = true
        offlineCleanupMessage = "已提交离线盘记录清理请求，等待 NAS Core 验证…"
        do {
            let encoded = Data(oldPath.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            try pipe.write(contentsOf: Data(("share forget " + encoded + "\n").utf8))
        } catch {
            offlineCleanupPending = false
            offlineCleanupMessage = "无法发送清理请求：\(error.localizedDescription)"
        }
    }

    func openDiskFormattingGuide(for volume: HostVolume) {
        guard StorageVolumeSelection.canInspectExternalVolume(mount: volume.mount),
              modelVolumeIsCurrent(volume) else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "使用 macOS 磁盘工具格式化「\(volume.name)」"
        alert.informativeText = """
        磁盘：\(volume.name)
        挂载点：\(volume.mount)
        设备：\(volume.device)
        格式：\(volume.filesystem)

        抹掉/格式化会删除选中磁盘上的全部现有文件，无法自动恢复。请先在另一块磁盘备份数据。

        推荐 APFS：仅在 Mac 上长期使用；如需 Mac 和 Windows 共用，选择 exFAT。系统磁盘工具中开启「显示所有设备」，确认容量及设备名称无误，再选择正确目标点击「抹掉」。LightIsle 不会自动格式化或提权。
        """
        alert.addButton(withTitle: "打开 macOS 磁盘工具")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let utility = URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app")
        NSWorkspace.shared.open(utility)
    }

    private func modelVolumeIsCurrent(_ volume: HostVolume) -> Bool {
        metrics?.volumes?.contains(where: {
            $0.mount == volume.mount && $0.device == volume.device && $0.filesystem == volume.filesystem
        }) == true
    }

    func selectSharedFolder(onVolume volume: HostVolume? = nil) {
        guard canChangeSharedStorage else {
            storageSelectionMessage = "请先等待正在进行的备份、迁移或存储切换结束，再修改存储目录。"
            return
        }
        if let volume, !StorageVolumeSelection.canChooseOnVolume(
            mount: volume.mount, readOnly: volume.readOnly
        ) {
            storageSelectionMessage = "此磁盘不可作为快捷选择目标。请选择已挂载的可写外置磁盘。"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "使用此目录"
        if let volume {
            panel.directoryURL = URL(fileURLWithPath: volume.mount, isDirectory: true)
            panel.message = "请在「\(volume.name)」磁盘内新建或选择 LightIsle 专用文件夹。不能直接共享整个磁盘，所选目录中的文件将对已授权的 NAS 用户开放。"
        } else {
            panel.message = "选择 Mac 用户主目录下的文件夹或外置磁盘内的专用文件夹。已授权 NAS 用户可读写其中的文件；不要选择包含密钥的目录。"
        }
        guard panel.runModal() == .OK, let selected = panel.url?.path else { return }
        let resolvedSelected = URL(fileURLWithPath: selected).resolvingSymlinksInPath().path
        if StorageVolumeSelection.canChooseOnVolume(mount: resolvedSelected, readOnly: false) {
            storageSelectionMessage = "不要把整块外置磁盘作为共享目录。请在磁盘内新建并选择 LightIsle 专用文件夹。"
            return
        }
        if let volume {
            let realMount = URL(fileURLWithPath: volume.mount).resolvingSymlinksInPath().path
            guard selected != volume.mount,
                  StorageVolumeSelection.contains(selected, in: volume.mount),
                  resolvedSelected != realMount,
                  StorageVolumeSelection.contains(resolvedSelected, in: realMount) else {
                storageSelectionMessage = "请在此磁盘中选择独立文件夹，不要选磁盘根目录、其他磁盘或指向其他位置的快捷链接。"
                return
            }
        }
        if selected == sharedFolderPath {
            storageSelectionMessage = "当前已经使用该文件夹，无须重复设置。"
            return
        }
        let oldRoot = sharedFolderPath
        if let oldRoot {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "确定切换 NAS 存储位置？"
            alert.informativeText = "原目录：\(oldRoot)\n新目录：\(selected)\n\n原目录的文件不会搬迁或删除，新目录也不会自动合并旧内容。图库与影院将重新扫描，正在使用的分享与上传应在切换后核查；管理员账号保留。建议先独立备份原数据。"
            alert.addButton(withTitle: "确认切换（不迁移文件）")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let code = Data(selected.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard let pipe = inputPipe?.fileHandleForWriting else {
            storageSelectionMessage = "NAS Core 尚未连接，无法修改目录。"
            return
        }
        pendingStorageTarget = selected
        previousStorageRoot = oldRoot
        storageSelectionPending = true
        storageSelectionMessage = "正在验证并切换共享目录…"
        do {
            try pipe.write(contentsOf: Data(("share set " + code + "\n").utf8))
            storageSelectionDeadline?.cancel()
            storageSelectionDeadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                guard let self, !Task.isCancelled, self.storageSelectionPending,
                      self.pendingStorageTarget == selected else { return }
                self.clearPendingStorageSelection()
                self.storageSelectionMessage = "未及时收到后端确认。请检查当前共享路径和 Core 状态后再操作；不能据此断言切换成功或失败。"
            }
        } catch {
            clearPendingStorageSelection()
            storageSelectionMessage = "无法向 NAS Core 提交存储设置：\(error.localizedDescription)"
        }
    }

    func retrySharedFolder() {
        guard state == .online, !storageSelectionPending, !offlineCleanupPending else { return }
        sharedFolderError = nil
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("share retry\n".utf8))
    }

    /// A cross-volume transfer is only requested from the native owner UI.
    /// Neither the selected source nor target is exposed to the Web API.
    func exportToAnotherDisk() {
        guard state == .online, !exportRunning, let base = sharedFolderPath else { return }
        let share = URL(fileURLWithPath: base, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()

        let sourcePanel = NSOpenPanel()
        sourcePanel.directoryURL = share
        sourcePanel.canChooseDirectories = true
        sourcePanel.canChooseFiles = true
        sourcePanel.allowsMultipleSelection = false
        sourcePanel.canCreateDirectories = false
        sourcePanel.prompt = "选择复制来源"
        sourcePanel.message = "选择共享目录内的文件或文件夹；源文件不会移动或删除。"
        guard sourcePanel.runModal() == .OK, let sourceURL = sourcePanel.url else { return }
        let selected = sourceURL.standardizedFileURL.path
        let prefix = share.path + "/"
        guard selected.hasPrefix(prefix) else {
            exportMessage = "只能复制当前共享目录里的文件或子文件夹。"
            return
        }
        let relative = String(selected.dropFirst(prefix.count))

        let destinationPanel = NSOpenPanel()
        destinationPanel.canChooseDirectories = true
        destinationPanel.canChooseFiles = false
        destinationPanel.allowsMultipleSelection = false
        destinationPanel.canCreateDirectories = true
        destinationPanel.prompt = "复制到此目录"
        destinationPanel.message = "先复制并校验 SHA-256，再原子发布。目标同名文件不会被覆盖，不能选择共享目录内部。"
        guard destinationPanel.runModal() == .OK, let destination = destinationPanel.url else { return }

        let modeAlert = NSAlert()
        modeAlert.messageText = "选择跨磁盘操作"
        modeAlert.informativeText = "安全复制：源文件保持原样。\n安全移动：仅支持普通文件，先完整复制、SHA-256 校验并持久记录，成功后才把源文件移至轻屿回收站；目标永不覆盖已有文件。发生错误或停电可能保留源与目标两个副本，不会主动销毁源数据。"
        modeAlert.alertStyle = .warning
        modeAlert.addButton(withTitle: "安全复制")
        modeAlert.addButton(withTitle: "复制后移入回收站")
        modeAlert.addButton(withTitle: "取消")
        let pickedMode = modeAlert.runModal()
        guard pickedMode != .alertThirdButtonReturn else { return }
        let mode = pickedMode == .alertSecondButtonReturn ? "move" : "copy"
        if mode == "move" {
            let attrs = try? FileManager.default.attributesOfItem(atPath: selected)
            guard attrs?[.type] as? FileAttributeType == .typeRegular else {
                exportMessage = "跨盘安全移动仅支持单个普通文件；文件夹请先安全复制。"
                return
            }
        }

        struct ExportRequest: Encodable {
            let source: String
            let destination: String
            let mode: String
        }
        guard let data = try? JSONEncoder().encode(ExportRequest(source: relative, destination: destination.path, mode: mode)) else {
            exportMessage = "无法创建复制请求。"
            return
        }
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        exportRunning = true
        activeExportMode = mode
        exportMessage = mode == "move"
            ? "正在执行日志化安全移动：复制、校验、写入恢复日志，再把源文件移入回收站。"
            : "正在复制并验证内容。源文件保持不变。"
        do {
            try inputPipe?.fileHandleForWriting.write(contentsOf: Data(("export start " + encoded + "\n").utf8))
        } catch {
            exportRunning = false
            exportMessage = "无法发送复制任务：\(error.localizedDescription)"
        }
    }

    func cancelExport() {
        guard exportRunning, state == .online else { return }
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("export cancel\n".utf8))
        exportMessage = "正在请求取消跨磁盘复制，清理尚未发布的临时副本…"
    }

    func requestTransferHistory() {
        guard state == .online else { return }
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("export history\n".utf8))
    }

    private func decodeExportResult(_ raw: String) -> String? {
        guard raw.count <= 8192 else { return nil }
        var normalized = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private init() {}

    private func decodeAdminUsername(_ raw: String) -> String? {
        var value = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value),
              let username = String(data: data, encoding: .utf8),
              !username.isEmpty, username.utf8.count <= 32 else { return nil }
        return username
    }

    func launch() {
        guard core == nil, !stopping else { return }
        diskOperationDeadline?.cancel()
        diskOperationPending = false
        managedDisks = []
        offlineCleanupPending = false
        offlineSharedFolderPath = nil
        clearPendingStorageSelection()
        cancelStartupDeadline()
        coreOutputFramer.reset()
        lastShareStatusPollAt = .distantPast
        cancelScheduledIndexRefresh()
        rootManagement.disconnect()
        endServicePolling()
        directoryWatcher?.stop()
        directoryWatcher = nil
        sharedFolderPath = nil
        if exportRunning {
            exportMessage = "Go Core 已停止，跨磁盘复制已中断；原文件不会自动删除，请检查目标磁盘有无未发布的临时副本。"
        }
        exportRunning = false
        let exe = ProcessInfo.processInfo.environment["LIGHTISLE_CORE_PATH"]
            .map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.resourceURL?.appendingPathComponent("core/lightisled")

        guard let exe, FileManager.default.isExecutableFile(atPath: exe.path) else {
            state = .error("未找到内置的 Go Core。请使用 scripts/build-macos.sh 构建应用。")
            return
        }

        let web = ProcessInfo.processInfo.environment["LIGHTISLE_WEB_ROOT"]
            .map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.resourceURL?.appendingPathComponent("web")

        let process = Process()
        let generation = UUID()
        process.executableURL = exe
        process.arguments = [
            "-port", String(preferredLocalPort),
            "-web-root", web?.path ?? "",
            "-thumbnail-cache-bytes", String(preferredThumbnailCacheMiB * 1_048_576),
        ]
        if rootManagement.enabled { process.arguments?.append("-multi-root-preview") }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.coreGeneration == generation else { return }
                self.consume(bytes)
            }
        }
        process.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task { @MainActor [weak self] in self?.childDidExit(status: status, generation: generation) }
        }

        do {
            try process.run()
            core = process
            coreGeneration = generation
            inputPipe = input
            outputPipe = output
            endpoint = nil
            remoteAddress = nil
            remoteFingerprint = nil
            remoteError = nil
            sharedFolderPath = nil
            exportRunning = false
            exportMessage = nil
            isConfigured = nil
            metrics = nil
            metricHistory = []
            initializing = false
            initializationError = nil
            backupStatus = nil
            backupError = nil
            backupInventory = nil
            backupInventoryLoading = false
            smbListening = nil
            backupSchedule = nil
            firstAdminUsername = nil
            state = .starting
            details = "等待本机 Go Core 提供健康检查服务。"
            beginServicePolling()
            startStartupDeadline(generation: generation)
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            state = .error("启动 Go Core 失败：\(error.localizedDescription)")
            details = "检查应用签名、端口是否被占用及内置的 Go Core。"
        }
    }

    private func consume(_ bytes: Data) {
        for line in coreOutputFramer.append(bytes) {
            if line.hasPrefix("LIGHTISLE_ROOTS ") {
                rootManagement.consume(String(line.dropFirst("LIGHTISLE_ROOTS ".count)))
                continue
            }
            if line.hasPrefix("LIGHTISLE_ADMIN_ACCOUNT ") {
                let raw = String(line.dropFirst("LIGHTISLE_ADMIN_ACCOUNT ".count))
                if let username = decodeAdminUsername(raw) { firstAdminUsername = username }
                continue
            }
            if line.hasPrefix("LIGHTISLE_ALERTS ") {
                let raw = String(line.dropFirst("LIGHTISLE_ALERTS ".count))
                var normalized = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
                if raw.count <= 64_000, let data = Data(base64Encoded: normalized),
                   let alerts = try? JSONDecoder().decode([CorePersistentAlert].self, from: data) {
                    presentCoreAlerts(Array(alerts.prefix(100)))
                }
                continue
            }
            if line == "LIGHTISLE_EXPORT_STARTED" {
                exportRunning = true
                exportMessage = activeExportMode == "move"
                    ? "正在跨盘安全移动，源文件会在完整发布之后进入回收站。"
                    : "跨磁盘复制正在执行，校验完成后才会显示目标文件。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_EXPORT_HISTORY ") {
                let raw = String(line.dropFirst("LIGHTISLE_EXPORT_HISTORY ".count))
                if let text = decodeExportResult(raw), let bytes = text.data(using: .utf8),
                   let items = try? JSONDecoder().decode([FileTransferReceipt].self, from: bytes) {
                    transferHistory = items
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_EXPORT_HISTORY_ERROR ") {
                let raw = String(line.dropFirst("LIGHTISLE_EXPORT_HISTORY_ERROR ".count))
                exportMessage = "无法读取迁移记录：" + (decodeExportResult(raw) ?? "未知错误")
                continue
            }
            if line.hasPrefix("LIGHTISLE_EXPORT_OK ") {
                exportRunning = false
                let raw = String(line.dropFirst("LIGHTISLE_EXPORT_OK ".count))
                let location = decodeExportResult(raw) ?? "目标文件"
                exportMessage = activeExportMode == "move"
                    ? "安全移动已完成：\(location)。源文件位于轻屿回收站，可恢复；历史记录保留在本机。"
                    : "复制并校验完成：\(location)"
                requestTransferHistory()
                continue
            }
            if line.hasPrefix("LIGHTISLE_EXPORT_ERROR ") {
                exportRunning = false
                let raw = String(line.dropFirst("LIGHTISLE_EXPORT_ERROR ".count))
                let reason = decodeExportResult(raw) ?? "unknown_error"
                exportMessage = reason == "context canceled" ? "复制已取消，源文件保持不变。" : "跨磁盘复制未完成：\(reason)"
                continue
            }
            if line == "LIGHTISLE_ADMIN_VERIFIED" {
                verifyingAdmin = false
                if let credentials = pendingAdminCredentials {
                    do {
                        try AdminCredentialVault.save(credentials)
                        vaultMessage = "管理员身份验证成功，凭据已保存到 Touch ID 保护的钥匙串。"
                    } catch {
                        vaultMessage = error.localizedDescription
                    }
                }
                pendingAdminCredentials = nil
                continue
            }
            if line == "LIGHTISLE_BACKUP_CANCEL_REQUESTED" {
                backupError = "已请求取消任务，正在清理未完成的临时文件。"
                continue
            }
            if line == "LIGHTISLE_ADMIN_VERIFY_FAILED" {
                verifyingAdmin = false
                pendingAdminCredentials = nil
                vaultMessage = "当前轻屿管理员用户名或密码不正确。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_ADMIN_RESET_OK ") {
                resettingAdmin = false
                AdminCredentialVault.remove()
                unlockedAdminCredentials = nil
                pendingAdminCredentials = nil
                let raw = String(line.dropFirst("LIGHTISLE_ADMIN_RESET_OK ".count))
                if let username = decodeAdminUsername(raw) {
                    firstAdminUsername = username
                    resetAdminMessage = "已重置管理员「\(username)」的密码。请使用该用户名和新密码登录当前 Web，旧登录会话已失效。"
                } else {
                    resetAdminMessage = "密码已更新，但未能读取账号名称。请确认当前 Web 地址并重新登录。"
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_ADMIN_RESET_ERROR ") {
                resettingAdmin = false
                let code = String(line.dropFirst("LIGHTISLE_ADMIN_RESET_ERROR ".count))
                resetAdminMessage = code == "invalid_password" ? "新密码不符合长度或格式要求。" :
                    code == "admin_missing" ? "未找到可用的首任管理员。" : "修改管理员密码失败，请检查 Go 服务日志。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_BACKUP_INVENTORY ") {
                let raw = String(line.dropFirst("LIGHTISLE_BACKUP_INVENTORY ".count))
                var normalized = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
                backupInventoryLoading = false
                if let data = Data(base64Encoded: normalized),
                   let report = try? JSONDecoder().decode(NASBackupInventory.self, from: data) {
                    backupInventory = report
                } else {
                    backupError = "无法读取备份清单，请重试。"
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_DISKS ") {
                let raw = String(line.dropFirst("LIGHTISLE_DISKS ".count))
                var normalized = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
                if let data = Data(base64Encoded: normalized),
                   let disks = try? JSONDecoder().decode([ManagedDisk].self, from: data) {
                    managedDisks = disks
                    diskManagementError = nil
                } else {
                    diskManagementError = "无法解析磁盘状态，请刷新。"
                }
                diskOperationPending = false
                diskOperationDeadline?.cancel()
                continue
            }
            if line.hasPrefix("LIGHTISLE_DISKS_ERROR ") {
                diskOperationPending = false
                diskOperationDeadline?.cancel()
                diskManagementError = "磁盘操作未完成：\(line.dropFirst("LIGHTISLE_DISKS_ERROR ".count))。请刷新并核对硬盘状态。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_BACKUP_STATUS ") {
                let raw = String(line.dropFirst("LIGHTISLE_BACKUP_STATUS ".count))
                var normalized = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
                if let data = Data(base64Encoded: normalized),
                   let report = try? JSONDecoder().decode(NASBackupStatus.self, from: data) {
                    backupStatus = report
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_BACKUP_SCHEDULE ") {
                let raw = String(line.dropFirst("LIGHTISLE_BACKUP_SCHEDULE ".count))
                var normalized = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
                if let data = Data(base64Encoded: normalized),
                   let report = try? JSONDecoder().decode(NASBackupSchedule.self, from: data) {
                    backupSchedule = report
                }
                continue
            }
            if line == "LIGHTISLE_BACKUP_SCHEDULE_CHANGED" {
                backupError = nil
                try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("backup schedule status\n".utf8))
                continue
            }
            if line == "LIGHTISLE_BACKUP_STARTED" {
                backupError = nil
                nativeAlertDelivery.clear(key: "backup-failure")
                try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("backup status\n".utf8))
                continue
            }
            if line.hasPrefix("LIGHTISLE_BACKUP_ERROR ") {
                backupInventoryLoading = false
                backupError = String(line.dropFirst("LIGHTISLE_BACKUP_ERROR ".count))
                notifyImportantEvent("backup-failure", title: "轻屿备份操作失败", message: "备份或恢复操作未完成，请在本机存储页面查看错误。")
                continue
            }
            if line == "LIGHTISLE_SMB_STATUS 1" {
                smbListening = true
                continue
            }
            if line == "LIGHTISLE_SMB_STATUS 0" {
                smbListening = false
                continue
            }
            if line == "LIGHTISLE_CONFIGURED 1" {
                isConfigured = true
                continue
            }
            if line == "LIGHTISLE_CONFIGURED 0" {
                isConfigured = false
                continue
            }
            if line == "LIGHTISLE_INITIALIZED" {
                initializing = false
                isConfigured = true
                initializationError = nil
                continue
            }
            if line.hasPrefix("LIGHTISLE_INIT_ERROR ") {
                initializing = false
                let code = String(line.dropFirst("LIGHTISLE_INIT_ERROR ".count))
                switch code {
                case "already_configured":
                    isConfigured = true
                    initializationError = "管理员已经初始化，请登录 Web 使用。"
                case "invalid_credentials":
                    initializationError = "用户名格式或密码长度不符合要求。"
                default:
                    initializationError = "初始化失败，请检查 Go 服务日志。"
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_STATS ") {
                let raw = String(line.dropFirst("LIGHTISLE_STATS ".count))
                var encoded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
                if let data = Data(base64Encoded: encoded),
                   let reading = try? JSONDecoder().decode(HostMetrics.self, from: data) {
                    metrics = reading
                    checkLowDiskSpace(reading.volumes ?? [])
                    let point = MetricHistoryPoint(
                        time: Date(), cpu: reading.cpuPercent ?? 0,
                        memory: Double(reading.memoryUsed) / Double(max(reading.memoryTotal, 1)) * 100,
                        download: reading.networkDownBps ?? 0,
                        upload: reading.networkUpBps ?? 0
                    )
                    metricHistory.append(point)
                    if metricHistory.count > 120 { metricHistory.removeFirst(metricHistory.count - 120) }
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_REMOTE_ON ") {
                let words = line.split(separator: " ")
                if words.count == 3 {
                    remoteAddress = String(words[1])
                    remoteFingerprint = String(words[2])
                    remoteError = nil
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_ON ") {
                sharedFolderName = String(line.dropFirst("LIGHTISLE_SHARE_ON ".count))
                sharedFolderError = nil
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_PATH ") {
                let raw = String(line.dropFirst("LIGHTISLE_SHARE_PATH ".count))
                var encoded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
                if let data = Data(base64Encoded: encoded), let path = String(data: data, encoding: .utf8), path.hasPrefix("/") {
                    if storageSelectionPending, let pendingStorageTarget,
                       URL(fileURLWithPath: pendingStorageTarget).resolvingSymlinksInPath().standardizedFileURL.path ==
                       URL(fileURLWithPath: path).standardizedFileURL.path {
                        let old = previousStorageRoot
                        clearPendingStorageSelection()
                        if let old {
                            storageSelectionMessage = "已切换至 \(path)。旧目录 \(old) 内的文件仍保留，不会自动迁移。"
                        } else {
                            storageSelectionMessage = "已启用 NAS 存储目录：\(path)"
                        }
                    }
                    cancelScheduledIndexRefresh()
                    sharedFolderPath = path
                    offlineSharedFolderPath = nil
                    if offlineCleanupMessage?.hasPrefix("已解除离线盘绑定") == true {
                        offlineCleanupMessage = "离线磁盘的本地媒体索引和旧共享权限已清理。现在使用本机存储目录 \(path)；原外接盘上的文件未删除。"
                    }
                    if timeMachineDiagnostics == nil { refreshTimeMachineDiagnostics() }
                    nativeAlertDelivery.clear(key: "volume-unavailable")
                    directoryWatcher?.stop()
                    directoryWatcher = DirectoryChangeWatcher(path: path) { [weak self] paths, full in
                        self?.scheduleIndexRefresh(paths: paths, needsFull: full)
                    }
                }
                continue
            }
            if line == "LIGHTISLE_SHARE_STATUS 0" {
                // Monitoring a disconnected volume must not keep displaying
                // the old path as live, or continue watching the old mount.
                // Reopening it is still an explicit, identity-checked action.
                if sharedFolderPath != nil || sharedFolderError == nil {
                    cancelScheduledIndexRefresh()
                    directoryWatcher?.stop()
                    directoryWatcher = nil
                    sharedFolderPath = nil
                    sharedFolderError = "原共享磁盘已离线或目录身份发生变化，请确认原磁盘后手动点击重新连接。"
                    notifyImportantEvent("volume-unavailable", title: "NAS 存储目录不可用",
                                         message: "轻屿已停止显示原共享目录为在线；不会自动改用同名磁盘。")
                }
                continue
            }
            if line == "LIGHTISLE_SHARE_STATUS 1" { continue }
            if line.hasPrefix("LIGHTISLE_SHARE_OFFLINE_PATH ") {
                let encoded = String(line.dropFirst("LIGHTISLE_SHARE_OFFLINE_PATH ".count))
                var raw = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
                if let data = Data(base64Encoded: raw),
                   let path = String(data: data, encoding: .utf8),
                   path.hasPrefix("/"), path.utf8.count <= 4096 {
                    offlineSharedFolderPath = path
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_FORGOT ") {
                offlineCleanupPending = false
                offlineSharedFolderPath = nil
                offlineCleanupMessage = "已解除离线盘绑定。原盘实际文件未删除；旧路径的图库、影院记录正在清理，NAS 正切换到本机目录。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_FORGET_ERROR ") {
                offlineCleanupPending = false
                let error = String(line.dropFirst("LIGHTISLE_SHARE_FORGET_ERROR ".count))
                offlineCleanupMessage = error.contains("shared_directory_save_uncertain_restart_required")
                    ? "目录配置持久化结果不确定。请停止文件操作，完全退出后重启 LightIsle，并检查当前实际共享目录。"
                    : "清理失败或当前存在进行中任务：\(error)。原绑定仍保留。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_FORGET_WARNING ") {
                offlineCleanupMessage = "已切回本机目录，但有部分媒体索引未完成清理：\(line.dropFirst("LIGHTISLE_SHARE_FORGET_WARNING ".count))。请先备份并检查元数据。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_ERROR ") {
                if storageSelectionPending {
                    let error = String(line.dropFirst("LIGHTISLE_SHARE_ERROR ".count))
                    clearPendingStorageSelection()
                    if error.contains("shared_directory_save_uncertain_restart_required") {
                        storageSelectionMessage = "存储目录配置落盘结果不确定。请停止文件操作，完全退出并重新启动轻屿，检查当前共享路径和磁盘身份后再继续。"
                    } else {
                        storageSelectionMessage = "更改存储目录失败：\(error)。当前运行中的原目录未被切换。"
                    }
                    continue
                }
                cancelScheduledIndexRefresh()
                sharedFolderError = String(line.dropFirst("LIGHTISLE_SHARE_ERROR ".count))
                sharedFolderPath = nil
                notifyImportantEvent("volume-unavailable", title: "NAS 存储目录不可用", message: "共享目录可能已断开连接；LightIsle 不会自动改用其他同名目录。")
                directoryWatcher?.stop()
                directoryWatcher = nil
                continue
            }
            if line == "LIGHTISLE_REMOTE_OFF" {
                remoteAddress = nil
                remoteFingerprint = nil
                continue
            }
            if line.hasPrefix("LIGHTISLE_REMOTE_ERROR ") {
                remoteError = String(line.dropFirst("LIGHTISLE_REMOTE_ERROR ".count))
                continue
            }
            guard line.hasPrefix("LIGHTISLE_READY ") else { continue }
            let raw = String(line.dropFirst("LIGHTISLE_READY ".count))
            guard let url = URL(string: raw),
                  url.scheme == "http", url.host == "127.0.0.1" else { continue }
            endpoint = url
            cancelStartupDeadline()
            state = .online
            details = "本机 Go Core 已就绪；如尚未初始化，将显示原生管理员设置页面。"
            rootManagement.connect { [weak self] command in
                guard let self, self.state == .online, let pipe = self.inputPipe else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try pipe.fileHandleForWriting.write(contentsOf: Data(command.utf8))
            }
        }
    }

    private func childDidExit(status: Int32, generation: UUID) {
        guard core != nil, coreGeneration == generation else { return }
        diskOperationDeadline?.cancel()
        if diskOperationPending { diskManagementError = "Core 已退出，磁盘操作结果未知，请重新启动并刷新。" }
        diskOperationPending = false
        managedDisks = []
        if offlineCleanupPending {
            offlineCleanupMessage = "Core 中断，无法确认离线盘清理状态。重启后检查当前共享路径及元数据。"
        }
        offlineCleanupPending = false
        if storageSelectionPending {
            storageSelectionMessage = "Core 已退出，无法确认存储切换结果；请重新启动并检查当前目录。"
        }
        clearPendingStorageSelection()
        cancelStartupDeadline()
        coreOutputFramer.reset()
        cancelScheduledIndexRefresh()
        endServicePolling()
        rootManagement.disconnect()
        // A late termination callback from a completed stop must not change
        // the app back to an error state.
        directoryWatcher?.stop()
        directoryWatcher = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        coreOutputFramer.reset()
        outputPipe = nil
        inputPipe = nil
        core = nil
        coreGeneration = nil
        endpoint = nil
        metrics = nil
        remoteAddress = nil
        remoteFingerprint = nil
        isConfigured = nil
        metrics = nil
        initializing = false
        backupStatus = nil
        backupError = nil
        backupInventoryLoading = false
        backupInventory = nil
        smbListening = nil
        remoteAddress = nil
        remoteFingerprint = nil
        if !stopping {
            state = .error("Go Core 异常退出，退出码 \(status)")
            details = "后端已停止。可点击“重新启动”恢复服务。"
        }
    }

    func stop() async {
        cancelStartupDeadline()
        cancelScheduledIndexRefresh()
        endServicePolling()
        rootManagement.disconnect()
        guard let process = core else { return }
        directoryWatcher?.stop()
        directoryWatcher = nil
        stopping = true
        state = .stopping
        endpoint = nil
        if let input = inputPipe?.fileHandleForWriting {
            // Child might already have exited; a broken pipe is not fatal.
            try? input.write(contentsOf: Data("shutdown\n".utf8))
            input.closeFile()
        }
        // The HTTP server must finish requests and close its listener first.
        for _ in 0..<40 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            process.terminate()
            for _ in 0..<15 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            for _ in 0..<10 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        inputPipe = nil
        core = nil
        coreGeneration = nil
        stopping = false
        backupInventoryLoading = false
        state = .offline
    }
}

