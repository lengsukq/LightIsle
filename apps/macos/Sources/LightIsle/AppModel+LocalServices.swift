import Foundation

@MainActor
extension AppModel {
    // MARK: - Local integrations

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
        tmdbTokenBusy = true
        guard state == .online, let data = token.data(using: .utf8) else {
            // Saved locally; the Core-online handler re-sends it.
            return
        }
        writeCinemaIPC("cinema tmdb set " + Self.base64URL(data))
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
        mapKeyError = nil
        mapKeyBusy = true
        if state == .online, let data = key.data(using: .utf8) {
            writeMapIPC("map tianditu set " + Self.base64URL(data))
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
        guard !mapCoreAcknowledged, let key = MapSecretVault.load(),
              let data = key.data(using: .utf8) else {
            refreshMapKeyStatus()
            return
        }
        mapKeyBusy = true
        writeMapIPC("map tianditu set " + Self.base64URL(data))
    }

    func clearTmdbToken() {
        TmdbSecretVault.remove()
        tmdbTokenBusy = true
        tmdbCoreAcknowledged = false
        writeCinemaIPC("cinema tmdb clear")
        if state != .online {
            tmdbTokenConfigured = false
            tmdbTokenBusy = false
        }
    }

    func refreshTmdbStatus() {
        guard state == .online else { return }
        writeCinemaIPC("cinema tmdb status")
    }

    // MARK: Trash retention

    func refreshTrashRetention() {
        guard state == .online else { return }
        writeCinemaIPC("trash retention")
    }

    func applyTrashRetention(days: Int, enabled: Bool) {
        guard state == .online, !trashRetentionBusy, let pipe = coreCommands else { trashRetentionError = "核心服务未就绪，保留规则尚未保存。"; return }
        guard (1...365).contains(days) || !enabled else {
            trashRetentionError = "保留天数需在 1 至 365 之间。"
            return
        }
        struct Payload: Codable { let enabled: Bool; let days: Int }
        guard let data = try? JSONEncoder().encode(Payload(enabled: enabled, days: days)) else { return }
        trashRetentionError = nil
        trashRetentionBusy = true
        trashDeadline?.cancel()
        trashDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            self.trashRetentionBusy = false
            self.trashRetentionError = "尚未收到保留规则的保存结果，请刷新后重试。"
        }
        do { try pipe.write(contentsOf: Data(("trash retention " + Self.base64URL(data) + "\n").utf8)) }
        catch { trashDeadline?.cancel(); trashRetentionBusy = false; trashRetentionError = "保存保留规则失败，请检查服务状态。" }
    }

    func loadTmdbSecretAndResend() {
        // Called when the Core becomes online: the new process knows nothing
        // about the token until the Keychain copy is re-sent once.
        guard !tmdbCoreAcknowledged, let token = TmdbSecretVault.load() else {
            if TmdbSecretVault.load() == nil {
                refreshTmdbStatus()
            }
            return
        }
        tmdbTokenBusy = true
        guard let data = token.data(using: .utf8) else { return }
        writeCinemaIPC("cinema tmdb set " + Self.base64URL(data))
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
        notifyError = nil
        notifyTestResult = nil
        notifyBusy = true
        guard state == .online, let data = try? JSONEncoder().encode(config) else {
            // Saved locally; the Core-online handler re-sends it.
            return
        }
        writeNotifyIPC("notify set " + Self.base64URL(data))
    }

    func clearNotify() {
        NotifySecretVault.remove()
        notifyBusy = true
        notifyCoreAcknowledged = false
        notifyTestResult = nil
        writeNotifyIPC("notify forget")
        if state != .online {
            notifyConfigured = false
            notifyStats = nil
            notifyBusy = false
        }
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
        // Called when the Core becomes online: the fresh process holds no
        // channel secrets until the Keychain copy is re-sent once.
        guard !notifyCoreAcknowledged, let config = NotifySecretVault.load(), !config.isEmpty else {
            if NotifySecretVault.load() == nil {
                refreshNotifyStatus()
            }
            return
        }
        notifyBusy = true
        guard let data = try? JSONEncoder().encode(config) else { return }
        writeNotifyIPC("notify set " + Self.base64URL(data))
    }
}
