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
            try inputPipe?.fileHandleForWriting.write(contentsOf: Data("index scan\n".utf8))
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

    func cancelScheduledIndexRefresh() {
        scanRefreshTask?.cancel()
        scanRefreshTask = nil
        pendingMediaDirs.removeAll()
        pendingFullMediaScan = false
    }

    func scheduleIndexRefresh(paths: [String]?, needsFull: Bool) {
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

    func saveLocalPort(_ text: String) -> Bool {
        guard let value = Int(text), (1024...65535).contains(value) else {
            portError = "端口必须是 1024–65535 之间的整数。"
            return false
        }
        UserDefaults.standard.set(value, forKey: "lightisle.localPort")
        portError = nil
        return true
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
            // Do not keep a partially initialized backend running. Retain
            // the normal parent-owned shutdown and require an explicit retry.
            await self.stop()
            guard self.core == nil, self.state == .offline else { return }
            self.state = .error("Go Core 启动超时（20 秒内未报告就绪）")
            self.details = "已停止未就绪的后端。请检查数据库恢复状态、端口占用和本机错误日志，再手动重试。"
        }
    }

    func beginServicePolling() {
        servicePollingTask?.cancel()
        servicePollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.refreshMetrics()
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
