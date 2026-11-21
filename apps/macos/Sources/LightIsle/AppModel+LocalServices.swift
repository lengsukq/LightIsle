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
        Task { @MainActor [weak self] in
            let presence = await Task.detached(priority: .utility) {
                let hasTmdb = TmdbSecretVault.load() != nil
                let hasMap = MapSecretVault.load() != nil
                let notify = NotifySecretVault.load()
                let hasNotify = (notify != nil && notify?.isEmpty == false)
                return (hasTmdb, hasMap, hasNotify)
            }.value
            guard let self else { return }
            if self.hasSavedTmdbToken != presence.0 { self.hasSavedTmdbToken = presence.0 }
            if self.hasSavedMapKey != presence.1 { self.hasSavedMapKey = presence.1 }
            if self.hasSavedNotifySecret != presence.2 { self.hasSavedNotifySecret = presence.2 }
        }
    }

    // MARK: TMDB token (cinema auto-scrape)

    private func writeCinemaIPC(_ line: String) {
        guard state == .online, let pipe = coreCommands else {
            tmdbTokenBusy = false
            return
        }
        do {
            try pipe.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            tmdbTokenBusy = false
            tmdbTokenError = UserFacingErrorMapper.coreIPCCommandError(action: "TMDB 设置同步")
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
            tmdbTokenError = (error as? LocalizedError)?.errorDescription
                ?? "无法将 TMDB Token 写入本机钥匙串，现有数据未受影响。请解锁登录钥匙串后重试。"
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
            mapKeyError = UserFacingErrorMapper.coreIPCCommandError(action: "天地图配置同步")
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
            mapKeyError = (error as? LocalizedError)?.errorDescription
                ?? "无法将天地图 Key 写入本机钥匙串，原有配置未受影响。请解锁登录钥匙串后重试。"
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
            mapKeyError = (error as? LocalizedError)?.errorDescription
                ?? "无法从本机钥匙串清除天地图 Key，原有配置仍保留。请解锁登录钥匙串后重试。"
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
        Task { @MainActor [weak self] in
            let loaded = await Task.detached(priority: .utility) { MapSecretVault.load() }.value
            guard let self else { return }
            self.hasSavedMapKey = loaded != nil
            guard !self.mapCoreAcknowledged, let key = loaded,
                  let data = key.data(using: .utf8) else {
                self.refreshMapKeyStatus()
                return
            }
            self.mapKeyBusy = true
            self.writeMapIPC("map tianditu set " + data.base64URLEncodedString)
        }
    }

    func clearTmdbToken() {
        do {
            try TmdbSecretVault.remove()
        } catch {
            tmdbTokenError = (error as? LocalizedError)?.errorDescription
                ?? "无法从本机钥匙串清除 TMDB Token，原有配置仍保留。请解锁登录钥匙串后重试。"
            return
        }
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
        Task { @MainActor [weak self] in
            let loaded = await Task.detached(priority: .utility) { TmdbSecretVault.load() }.value
            guard let self else { return }
            self.hasSavedTmdbToken = loaded != nil
            guard !self.tmdbCoreAcknowledged, let token = loaded else {
                if loaded == nil {
                    self.refreshTmdbStatus()
                }
                return
            }
            guard let data = token.data(using: .utf8) else { return }
            self.tmdbTokenBusy = true
            self.writeCinemaIPC("cinema tmdb set " + data.base64URLEncodedString)
        }
    }

    // MARK: Outbound notifications (Bark / webhook)

    private func writeNotifyIPC(_ line: String) {
        guard state == .online, let pipe = coreCommands else {
            notifyBusy = false
            return
        }
        do {
            try pipe.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            notifyBusy = false
            notifyError = UserFacingErrorMapper.coreIPCCommandError(action: "通知渠道配置同步")
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
            notifyError = (error as? LocalizedError)?.errorDescription
                ?? "无法将通知凭据写入本机钥匙串，原有设置未受影响。请解锁登录钥匙串后重试。"
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
        do {
            try NotifySecretVault.remove()
        } catch {
            notifyError = (error as? LocalizedError)?.errorDescription
                ?? "无法从本机钥匙串清除通知凭据，原有配置仍保留。请解锁登录钥匙串后重试。"
            return
        }
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
        Task { @MainActor [weak self] in
            let loaded = await Task.detached(priority: .utility) { NotifySecretVault.load() }.value
            guard let self else { return }
            self.hasSavedNotifySecret = (loaded != nil && loaded?.isEmpty == false)
            guard !self.notifyCoreAcknowledged, let config = loaded, !config.isEmpty else {
                if loaded == nil {
                    self.refreshNotifyStatus()
                }
                return
            }
            guard let data = try? JSONEncoder().encode(config) else { return }
            self.notifyBusy = true
            self.writeNotifyIPC("notify set " + data.base64URLEncodedString)
        }
    }
}
