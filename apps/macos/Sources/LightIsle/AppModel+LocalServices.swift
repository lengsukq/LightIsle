import Foundation

@MainActor
extension AppModel {
    // MARK: - Local integrations

    func refreshCachedSecretPresence() {
        guard !isPresentationPreview else {
            hasSavedTmdbToken = false
            hasSavedMapKey = false
            hasSavedNotifySecret = false
            return
        }
        hasSavedTmdbToken = TmdbSecretVault.load() != nil
        hasSavedMapKey = MapSecretVault.load() != nil
        if let notify = NotifySecretVault.load(), !notify.isEmpty {
            hasSavedNotifySecret = true
        } else {
            hasSavedNotifySecret = false
        }
    }

    // MARK: TMDB token (cinema auto-scrape)

    private func writeCinemaIPC(_ line: String) {
        guard state == .online, let pipe = coreCommands else { return }
        do {
            try pipe.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            tmdbTokenError = "无法发送 TMDB 命令：\(error.localizedDescription)"
        }
    }

    /// Validates and stores the TMDB token in the Keychain, then mirrors it
    /// into Core memory. The token itself never appears in errors, logs or
    /// the UI state.
    func configureTmdbToken(_ token: String) {
        guard TmdbTokenValidation.isValid(token) else {
            tmdbTokenError = "Token 格式不正确：应为 TMDB v4 Read Access Token（长度 20 以上的连续字符串，不含空格换行）。"
            return
        }
        tmdbTokenError = nil
        do {
            try TmdbSecretVault.save(token)
        } catch {
            tmdbTokenError = "写入钥匙串失败：\(error.localizedDescription)"
            return
        }
        hasSavedTmdbToken = true
        guard state == .online, let data = token.data(using: .utf8) else {
            // Saved locally; reset busy so UI stays responsive while Core is offline.
            tmdbTokenBusy = false
            return
        }
        tmdbTokenBusy = true
        writeCinemaIPC("cinema tmdb set " + data.base64URLEncodedString)
    }

    // MARK: Tianditu map service (private Mac Keychain and Core IPC)

    @discardableResult
    private func writeMapIPC(_ line: String) -> Bool {
        guard state == .online, let pipe = coreCommands else {
            mapKeyBusy = false
            mapKeyError = "Core 服务尚未就绪，Key 已保存在 Mac 钥匙串，启动服务后会重新同步。"
            return false
        }
        do {
            try pipe.write(contentsOf: Data((line + "\n").utf8))
            return true
        } catch {
            mapKeyBusy = false
            mapKeyError = "无法同步天地图配置至 Core，请检查服务状态并重新操作：\(error.localizedDescription)"
            return false
        }
    }

    func configureMapKey(_ key: String) {
        guard MapSecretVault.valid(key) else {
            mapKeyError = "天地图 Key 格式无效，请粘贴 8 至 128 位字母、数字或 -、_。"
            return
        }
        do {
            try MapSecretVault.save(key)
        } catch {
            mapKeyError = "无法保存天地图 Key 至 Mac 钥匙串：\(error.localizedDescription)"
            return
        }
        hasSavedMapKey = true
        mapKeyError = nil
        if state == .online, let data = key.data(using: .utf8) {
            mapKeyBusy = true
            writeMapIPC("map tianditu set " + data.base64URLEncodedString)
        } else {
            mapKeyBusy = false
        }
    }

    func clearMapKey() {
        do {
            try MapSecretVault.remove()
        } catch {
            mapKeyError = "无法从 Mac 钥匙串删除 Key，原有配置仍保留：\(error.localizedDescription)"
            return
        }
        hasSavedMapKey = false
        mapKeyError = nil
        mapKeyConfigured = false
        mapCoreAcknowledged = false
        if state == .online {
            mapKeyBusy = true
            writeMapIPC("map tianditu clear")
        } else {
            mapKeyBusy = false
        }
    }

    func refreshMapKeyStatus() {
        guard state == .online else { return }
        writeMapIPC("map tianditu status")
    }

    func loadMapSecretAndResend() {
        let loaded = MapSecretVault.load()
        hasSavedMapKey = loaded != nil
        guard !mapCoreAcknowledged, let key = loaded,
              let data = key.data(using: .utf8) else {
            refreshMapKeyStatus()
            return
        }
        mapKeyBusy = true
        writeMapIPC("map tianditu set " + data.base64URLEncodedString)
    }

    func clearTmdbToken() {
        TmdbSecretVault.remove()
        hasSavedTmdbToken = false
        tmdbTokenError = nil
        tmdbCoreAcknowledged = false
        guard state == .online else {
            tmdbTokenConfigured = false
            tmdbTokenBusy = false
            return
        }
        tmdbTokenBusy = true
        writeCinemaIPC("cinema tmdb clear")
    }

    func refreshTmdbStatus() {
        guard state == .online else { return }
        writeCinemaIPC("cinema tmdb status")
    }

    func loadTmdbSecretAndResend() {
        let loaded = TmdbSecretVault.load()
        hasSavedTmdbToken = loaded != nil
        guard !tmdbCoreAcknowledged, let token = loaded else {
            if loaded == nil {
                refreshTmdbStatus()
            }
            return
        }
        guard let data = token.data(using: .utf8) else { return }
        tmdbTokenBusy = true
        writeCinemaIPC("cinema tmdb set " + data.base64URLEncodedString)
    }

    // MARK: Outbound notifications (Bark / webhook)

    private func writeNotifyIPC(_ line: String) {
        guard state == .online, let pipe = coreCommands else { return }
        do {
            try pipe.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            notifyError = "无法发送通知命令：\(error.localizedDescription)"
        }
    }

    /// Saves the channel configuration to the Keychain, then mirrors it into
    /// Core memory. Saved fields are never echoed back into UI state.
    func configureNotify(_ config: NotifyChannelConfig) {
        guard !config.isEmpty else {
            notifyError = "请至少配置 Bark、Webhook、SMTP、企业微信或钉钉其中一个通知渠道。"
            return
        }
        do {
            try NotifySecretVault.save(config)
        } catch {
            notifyError = "写入钥匙串失败：\(error.localizedDescription)"
            return
        }
        hasSavedNotifySecret = true
        notifyError = nil
        notifyTestResult = nil
        guard state == .online, let data = try? JSONEncoder().encode(config) else {
            // Saved locally; reset busy so UI stays responsive while Core is offline.
            notifyBusy = false
            return
        }
        notifyBusy = true
        writeNotifyIPC("notify set " + data.base64URLEncodedString)
    }

    func clearNotify() {
        NotifySecretVault.remove()
        hasSavedNotifySecret = false
        notifyError = nil
        notifyCoreAcknowledged = false
        notifyTestResult = nil
        guard state == .online else {
            notifyConfigured = false
            notifyStats = nil
            notifyBusy = false
            return
        }
        notifyBusy = true
        writeNotifyIPC("notify forget")
    }

    func refreshNotifyStatus() {
        guard state == .online else { return }
        writeNotifyIPC("notify status")
    }

    func testNotify() {
        notifyTestResult = nil
        guard state == .online else {
            notifyTestResult = "Core 服务未就绪，无法发送测试通知。"
            return
        }
        writeNotifyIPC("notify test")
    }

    func loadNotifySecretAndResend() {
        let loaded = NotifySecretVault.load()
        hasSavedNotifySecret = (loaded != nil && loaded?.isEmpty == false)
        guard !notifyCoreAcknowledged, let config = loaded, !config.isEmpty else {
            if loaded == nil {
                refreshNotifyStatus()
            }
            return
        }
        guard let data = try? JSONEncoder().encode(config) else { return }
        notifyBusy = true
        writeNotifyIPC("notify set " + data.base64URLEncodedString)
    }
}
