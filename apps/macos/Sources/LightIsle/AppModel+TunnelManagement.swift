import AppKit
import Foundation

@MainActor
extension AppModel {
    // MARK: - Tunnel management

    @discardableResult
    private func writeTunnelIPC(_ line: String) -> Bool {
        guard state == .online, let pipe = inputPipe?.fileHandleForWriting else {
            tunnelAPIError = "Core 服务未就绪，无法发送隧道命令。"
            return false
        }
        do {
            try pipe.write(contentsOf: Data((line + "\n").utf8))
            return true
        } catch {
            tunnelAPIError = "无法发送隧道命令：\(error.localizedDescription)"
            return false
        }
    }

    func refreshTunnel() {
        writeTunnelIPC("tunnel status")
    }

    @discardableResult
    private func writeFRPIPC(_ command: String) -> Bool {
        guard state == .online, let pipe = inputPipe?.fileHandleForWriting else {
            frpError = "Core 服务未就绪，请先启动服务。"
            return false
        }
        do {
            try pipe.write(contentsOf: Data((command + "\n").utf8))
            return true
        } catch {
            frpError = "无法发送 FRP 操作：\(error.localizedDescription)"
            return false
        }
    }

    func refreshFRP() { _ = writeFRPIPC("frp status") }

    func refreshFRPVersions() {
        guard !frpVersionsLoading else { return }
        frpError = nil
        frpVersionsLoading = true
        if !writeFRPIPC("frp versions") { frpVersionsLoading = false }
    }

    func selectFRPVersion(_ version: String) {
        guard frpVersions.contains(where: { $0.version == version }) else { return }
        selectedFRPVersion = version
    }

    func installFRP() {
        guard let release = frpVersions.first(where: {
            $0.version == selectedFRPVersion && $0.installable
        }) else {
            frpError = "请先获取版本列表，并选择可安装的 FRP 版本。"
            return
        }
        frpError = nil
        _ = writeFRPIPC("frp install " + release.version)
    }

    func startFRP() {
        frpError = nil
        _ = writeFRPIPC("frp start")
    }

    func stopFRP() {
        frpError = nil
        _ = writeFRPIPC("frp stop")
    }

    func openFRPConfig() {
        guard let path = frpState?.configPath, !path.isEmpty else {
            frpError = "配置文件路径未就绪，请先刷新 FRP 状态。"
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            frpError = "找不到配置文件，请刷新后重试。"
            return
        }
        if NSWorkspace.shared.open(url) {
            frpError = nil
        } else {
            // TOML might not have an associated app. TextEdit is always
            // available on macOS and avoids a second user action in Finder.
            let editorURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            if FileManager.default.fileExists(atPath: editorURL.path) {
                NSWorkspace.shared.open([url], withApplicationAt: editorURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error {
                        NSLog("FRP config editor launch failed: %@", error.localizedDescription)
                    }
                }
                frpError = nil
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                frpError = "未找到可打开 TOML 的默认编辑器，已在 Finder 中定位。"
            }
        }
    }

    func startQuickTunnel() {
        tunnelAPIError = nil
        writeTunnelIPC("tunnel quick on")
    }

    func stopTunnel() {
        tunnelAPIError = nil
        writeTunnelIPC("tunnel off")
    }

    /// Advanced escape hatch: run an existing tunnel by pasting its token.
    func runTunnelWithToken(_ token: String) {
        do {
            let command = try TunnelWireCodec.manualTokenCommand(token)
            tunnelAPIError = nil
            writeTunnelIPC(command)
        } catch {
            tunnelAPIError = "隧道 Token 格式不正确。"
        }
    }

    func tunnelAPI(operation: String, payload: [String: Any] = [:]) {
        guard state == .online else {
            tunnelAPIError = "Core 服务未就绪，无法发送隧道命令。"
            return
        }
        tunnelAPIBusy = true
        tunnelAPIError = nil
        do {
            let command = try TunnelWireCodec.apiCommand(operation: operation, payload: payload)
            if !writeTunnelIPC(command) { tunnelAPIBusy = false }
        } catch {
            tunnelAPIBusy = false
            tunnelAPIError = "隧道请求参数无效，请刷新后重试。"
        }
    }

    /// Validates and stores the Cloudflare API token in the Keychain, then
    /// reports the discovered accounts.
    func configureTunnelAPIToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else {
            tunnelAPIError = "API Token 格式不正确。"
            return
        }
        guard state == .online else {
            tunnelAPIError = "Core 尚未运行，无法验证或保存隧道 API Token。"
            return
        }
        tunnelCredential.stage(trimmed)
        tunnelAPI(operation: "configure", payload: ["apiToken": trimmed])
        if tunnelAPIError != nil { tunnelCredential.cancelPending() }
    }

    func forgetTunnelAPIToken() {
        do {
            try tunnelCredential.forget()
        } catch {
            tunnelAPIError = "无法从 macOS 钥匙串删除隧道 API Token，请解锁钥匙串后重试：\(error.localizedDescription)"
            return
        }
        tunnelAPITokenConfigured = false
        mapKeyConfigured = false
        mapKeyBusy = false
        mapCoreAcknowledged = false
        tunnelAccounts = []
        tunnelList = []
        tunnelIngress = []
        tunnelSelectedID = nil
        if state == .online { tunnelAPI(operation: "forget") }
    }

    func loadTunnelSecretAndResend() {
        // Called when the Core becomes online: the new process has no memory
        // of the API token, so the Keychain copy is re-validated once.
        guard !tunnelAPITokenConfigured, let token = tunnelCredential.storedToken() else { return }
        tunnelAPIBusy = true
        tunnelAPI(operation: "configure", payload: ["apiToken": token])
    }

    func selectTunnel(_ id: String?) {
        tunnelSelectedID = id
        tunnelIngress = []
        guard let id else { return }
        guard let entry = tunnelList.first(where: { $0.id == id }) else { return }
        guard let accountID = tunnelAccounts.first?.id else { return }
        tunnelAPI(operation: "config", payload: ["accountId": accountID, "tunnelId": id, "tunnelName": entry.name])
    }

    func applyTunnelPayload(_ payload: [String: Any]) {
        tunnelAPIBusy = false
        let snapshot = TunnelPayloadParser.parse(payload)
        if let list = snapshot.accounts {
            tunnelAccounts = list
            // Credential ownership is separate from the API response model:
            // Core validating a replacement never silently overwrites the
            // previous local credential on a failed Keychain operation.
            if snapshot.operation == "configure" {
                switch tunnelCredential.didValidateAccounts() {
                case .saved:
                    tunnelAPITokenConfigured = true
                    tunnelAPIError = nil
                case .unchanged(let savedLocally):
                    if !tunnelAPITokenConfigured { tunnelAPITokenConfigured = savedLocally }
                case .failed(let savedLocally, let reason):
                    tunnelAPITokenConfigured = savedLocally
                    tunnelAPIError = "新 API Token 已通过远端验证，但无法保存到 macOS 钥匙串。原有凭据（如存在）已保留；重启后将不会使用新 Token。请检查钥匙串权限并重新配置：\(reason)"
                }
            } else if !tunnelAPITokenConfigured && snapshot.operation == "accounts" {
                tunnelAPITokenConfigured = tunnelCredential.storedToken() != nil
            }
            if !list.isEmpty && tunnelSelectedID == nil {
                requestTunnelList()
            }
        }
        if let list = snapshot.zones {
            tunnelZones = list
        }
        if let list = snapshot.tunnels {
            tunnelList = list
            if tunnelSelectedID == nil, let first = list.first(where: { $0.remoteConfig }) {
                selectTunnel(first.id)
            }
        }
        if let entry = snapshot.createdTunnel {
            if !tunnelList.contains(where: { $0.id == entry.id }) {
                tunnelList.append(entry)
            }
            tunnelSelectedID = entry.id
            requestTunnelZones()
        }
        if snapshot.deleted {
            tunnelSelectedID = nil
            tunnelIngress = []
            requestTunnelList()
        }
        if let ingress = snapshot.ingress {
            tunnelIngress = ingress
        }
        if snapshot.forgotten {
            tunnelAPITokenConfigured = false
            tunnelAccounts = []
            tunnelZones = []
            tunnelList = []
            tunnelIngress = []
            tunnelSelectedID = nil
        }
    }

    func requestTunnelList() {
        guard let accountID = tunnelAccounts.first?.id else { return }
        tunnelAPI(operation: "tunnels", payload: ["accountId": accountID])
    }

    func requestTunnelZones() {
        tunnelAPI(operation: "zones")
    }

    func createTunnel(named name: String) {
        guard let accountID = tunnelAccounts.first?.id else { return }
        tunnelAPI(operation: "create", payload: ["accountId": accountID, "name": name])
    }

    func deleteTunnel(_ id: String) {
        guard let accountID = tunnelAccounts.first?.id else { return }
        tunnelAPI(operation: "delete", payload: ["accountId": accountID, "tunnelId": id])
    }

    /// One-click hostname onboarding: ensure the CNAME, upsert the ingress
    /// rule and keep every other rule intact (read-modify-write).
    func bindHostname(_ hostname: String, zoneID: String, service: String) {
        guard let tunnelID = tunnelSelectedID, let accountID = tunnelAccounts.first?.id else { return }
        let trimmedService = service.trimmingCharacters(in: .whitespaces)
        guard !hostname.isEmpty, !trimmedService.isEmpty else {
            tunnelAPIError = "主机名和服务地址不能为空。"
            return
        }
        tunnelAPI(operation: "route", payload: [
            "accountId": accountID, "tunnelId": tunnelID,
            "zoneId": zoneID, "hostname": hostname, "service": trimmedService,
        ])
    }

    func unbindHostname(_ hostname: String, zoneID: String) {
        guard let tunnelID = tunnelSelectedID, let accountID = tunnelAccounts.first?.id else { return }
        tunnelAPI(operation: "route-remove", payload: [
            "accountId": accountID, "tunnelId": tunnelID, "zoneId": zoneID, "hostname": hostname,
        ])
    }

    func startSelectedTunnel() {
        guard let tunnelID = tunnelSelectedID, let accountID = tunnelAccounts.first?.id else { return }
        let name = tunnelList.first(where: { $0.id == tunnelID })?.name ?? ""
        tunnelAPI(operation: "token", payload: ["accountId": accountID, "tunnelId": tunnelID, "tunnelName": name])
    }
}
