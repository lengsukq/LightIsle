import Foundation

@MainActor
extension AppModel {
    // MARK: - Remote access

    func finishRemoteChange() { remoteDeadline?.cancel(); remoteDeadline = nil; remoteBusy = false }

    func enablePreferredLANIfReady() {
        if let error = remoteError,
           !LANAccessPolicy.canRetryAfterNetworkChange(error) { return }
        guard LANAccessPolicy.shouldAutoEnable(
            coreOnline: state == .online,
            administratorReady: isConfigured == true,
            alreadyListening: remoteAddress != nil,
            changePending: remoteBusy
        ) else { return }
        guard Date().timeIntervalSince(lastAutomaticLANAttemptAt) >= 30 else { return }
        lastAutomaticLANAttemptAt = Date()
        setRemoteEnabled(true, rememberChoice: false)
    }

    func setRemoteEnabled(_ enabled: Bool, allowHTTP: Bool? = nil, rememberChoice: Bool = true) {
        guard state == .online, !remoteBusy, let pipe = coreCommands else { return }
        // Record the owner's intent independently of the current listener.
        // A failed bind or restart may leave the listener offline, but must
        // not silently turn the saved preference back off.
        if rememberChoice {
            prefersRemoteAccess = enabled
            LANAccessPolicy.rememberEnabled(enabled)
        }
        remoteError = nil
        remoteBusy = true
        remoteDeadline?.cancel()
        remoteDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            self.remoteBusy = false
            self.remoteError = "尚未收到连接设置结果，请刷新状态后重试。"
        }
        if let allowHTTP {
            allowLANHTTP = allowHTTP
            LANAccessPolicy.rememberHTTP(allowHTTP)
        }
        let command = enabled ? (allowLANHTTP ? "remote http on\n" : "remote on\n") : "remote off\n"
        do {
            try pipe.write(contentsOf: Data(command.utf8))
        }
        catch { finishRemoteChange(); remoteError = "无法发送连接设置，请检查核心服务状态。" }
    }
}
