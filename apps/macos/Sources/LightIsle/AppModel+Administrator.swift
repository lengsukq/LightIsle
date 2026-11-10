import AppKit
import Foundation
import LocalAuthentication

@MainActor
extension AppModel {
    // MARK: - Administrator security

    func saveAdministratorWithTouchID(username: String, password: String) {
        administratorSaveSucceeded = false
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
        try? coreCommands?.write(contentsOf: Data(("admin verify " + payload + "\n").utf8))
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
        administratorResetSucceeded = false
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
                guard approved, state == .online, let pipe = coreCommands else {
                    resettingAdmin = false
                    resetAdminMessage = "认证已取消或本地服务不可用。"
                    return
                }
                let payload = try JSONSerialization.data(withJSONObject: ["password": newPassword])
                let encoded = payload.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
                try pipe.write(contentsOf: Data(("admin reset " + encoded + "\n").utf8))
            } catch {
                resettingAdmin = false
                resetAdminMessage = "设备验证取消或失败，管理员密码未更改。"
            }
        }
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
        try? coreCommands?.write(contentsOf: Data(("admin init " + command + "\n").utf8))
    }

    func openUserWeb(page: String? = nil) {
        guard !isPresentationPreview else { webOpenError = "设计预览不连接真实服务。"; return }
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
}
