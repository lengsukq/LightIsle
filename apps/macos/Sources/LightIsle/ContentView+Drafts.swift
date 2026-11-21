import SwiftUI

enum NativeDraft: Hashable { case tmdb, map, notification, credentials, password, threshold }

/// Strongly-typed draft model for non-secret notification channel fields,
/// replacing the error-prone positional `[String]` baseline array.
struct NotificationDraft: Equatable {
    var barkServer: String = ""
    var webhookURL: String = ""
    var allowPrivateTargets: Bool = false
    var wecomWebhook: String = ""
    var dingtalkWebhook: String = ""
    var smtpHost: String = ""
    var smtpPort: String = "465"
    var smtpUsername: String = ""
    var smtpFrom: String = ""
    var smtpTo: String = ""

    init() {}

    init(from saved: NotifyChannelConfig) {
        barkServer = saved.barkServer
        webhookURL = saved.webhookURL
        allowPrivateTargets = saved.allowPrivateTargets
        wecomWebhook = saved.wecomWebhook ?? ""
        dingtalkWebhook = saved.dingtalkWebhook ?? ""
        smtpHost = saved.smtpHost ?? ""
        smtpPort = String(saved.smtpPort ?? 465)
        smtpUsername = saved.smtpUsername ?? ""
        smtpFrom = saved.smtpFrom ?? ""
        smtpTo = saved.smtpTo ?? ""
    }

    var hasAnyPublicChannel: Bool {
        !webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !wecomWebhook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !dingtalkWebhook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !smtpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func makeConfig(
        barkKeyDraft: String,
        smtpPasswordDraft: String,
        dingtalkSecretDraft: String,
        prior: NotifyChannelConfig?
    ) -> NotifyChannelConfig {
        let trimmedBarkKey = barkKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSMTPHost = smtpHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return NotifyChannelConfig(
            barkServer: barkServer.trimmingCharacters(in: .whitespacesAndNewlines),
            barkKey: trimmedBarkKey.isEmpty ? (prior?.barkKey ?? "") : trimmedBarkKey,
            webhookURL: webhookURL.trimmingCharacters(in: .whitespacesAndNewlines),
            allowPrivateTargets: allowPrivateTargets,
            smtpHost: trimmedSMTPHost.isEmpty ? nil : trimmedSMTPHost,
            smtpPort: trimmedSMTPHost.isEmpty ? nil : (Int(smtpPort) ?? 465),
            smtpUsername: trimmedSMTPHost.isEmpty ? nil : smtpUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            smtpPassword: trimmedSMTPHost.isEmpty ? nil : (smtpPasswordDraft.isEmpty ? prior?.smtpPassword : smtpPasswordDraft),
            smtpFrom: trimmedSMTPHost.isEmpty ? nil : smtpFrom.trimmingCharacters(in: .whitespacesAndNewlines),
            smtpTo: trimmedSMTPHost.isEmpty ? nil : smtpTo.trimmingCharacters(in: .whitespacesAndNewlines),
            wecomWebhook: wecomWebhook.trimmingCharacters(in: .whitespacesAndNewlines),
            dingtalkWebhook: dingtalkWebhook.trimmingCharacters(in: .whitespacesAndNewlines),
            dingtalkSecret: dingtalkSecretDraft.isEmpty ? prior?.dingtalkSecret : dingtalkSecretDraft
        )
    }
}

extension ContentView {
    var draftSaveSignal: NativeSaveSignal {
        NativeSaveSignal(pending: [model.tmdbTokenBusy, model.mapKeyBusy, model.notifyBusy, model.verifyingAdmin,
                                   model.resettingAdmin, childEdits.dirty, childEdits.busy,
                                   model.administratorSaveSucceeded, model.administratorResetSucceeded],
                         messages: [model.tmdbTokenError, model.mapKeyError, model.notifyError, model.vaultMessage,
                                    model.resetAdminMessage, childEdits.error],
                         threshold: [model.storageThreshold?.freeMiB, model.storageThreshold?.percent])
    }

    var notificationDirty: Bool { drafts.isNotificationDirty }
    var thresholdDirty: Bool { drafts.isThresholdDirty(current: model.storageThreshold) }
    var hasUnsavedDrafts: Bool {
        drafts.hasUnsavedChanges(
            childDirty: childEdits.dirty,
            preferredLocalPort: model.preferredLocalPort,
            storageThreshold: model.storageThreshold
        )
    }
    func resetNotificationDraft() { drafts.resetNotification() }
    func discardDrafts() {
        drafts.discardAll(preferredLocalPort: model.preferredLocalPort, discardChild: childEdits.discard)
    }
    func saveMediaDraft(_ kind: NativeDraft) {
        drafts.pendingSaves.insert(kind)
        if kind == .tmdb { model.configureTmdbToken(drafts.tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines)) }
        else { model.configureMapKey(drafts.tiandituKey.trimmingCharacters(in: .whitespacesAndNewlines)) }
        completeDraftSaveIfReady()
    }
    func saveNotificationDraft() {
        drafts.pendingSaves.insert(.notification)
        let draftSnapshot = drafts.notification
        let barkKey = drafts.notifyBarkKey
        let smtpPassword = drafts.notifySMTPPassword
        let dingtalkSecret = drafts.notifyDingtalkSecret
        let needsPriorLookup = barkKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || smtpPassword.isEmpty
            || dingtalkSecret.isEmpty
        Task { @MainActor in
            let prior: NotifyChannelConfig? = needsPriorLookup
                ? await Task.detached(priority: .userInitiated) { NotifySecretVault.load() }.value
                : nil
            model.configureNotify(draftSnapshot.makeConfig(
                barkKeyDraft: barkKey,
                smtpPasswordDraft: smtpPassword,
                dingtalkSecretDraft: dingtalkSecret,
                prior: prior
            ))
            completeDraftSaveIfReady()
        }
    }
    func saveCredentialDraft() {
        drafts.pendingSaves.insert(.credentials)
        model.saveAdministratorWithTouchID(username: drafts.vaultUsername, password: drafts.vaultPassword)
        completeDraftSaveIfReady()
    }
    func savePasswordDraft() {
        guard drafts.resetAdminPassword == drafts.resetAdminConfirmation else {
            drafts.draftError = "两次输入的新密码不同，请核对后保存。"
            return
        }
        drafts.pendingSaves.insert(.password)
        model.resetAdministratorPassword(newPassword: drafts.resetAdminPassword)
        completeDraftSaveIfReady()
    }
    func saveDraftsAndLeave() {
        drafts.draftError = nil
        // Running a tunnel is a separate consequential action, not saving a form.
        guard drafts.manualTunnelToken.isEmpty else {
            drafts.draftError = "隧道 Token 尚未使用。请在当前页面选择启动，或放弃输入后离开。"; return
        }
        if !drafts.localPortText.isEmpty, drafts.localPortText != String(model.preferredLocalPort), !model.saveLocalPort(drafts.localPortText) {
            drafts.draftError = model.portError; return
        }
        drafts.saveBeforeLeaving = true
        drafts.cancelTimeout()
        drafts.draftTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, drafts.saveBeforeLeaving else { return }
            drafts.saveBeforeLeaving = false
            drafts.draftError = "尚未收到完整保存结果，输入已保留。请检查服务状态后重试。"
        }
        if childEdits.dirty { childEdits.save?() }
        if !drafts.tmdbToken.isEmpty { saveMediaDraft(.tmdb) }
        if !drafts.tiandituKey.isEmpty { saveMediaDraft(.map) }
        if notificationDirty { saveNotificationDraft() }
        if !drafts.vaultPassword.isEmpty { saveCredentialDraft() }
        if !drafts.resetAdminPassword.isEmpty || !drafts.resetAdminConfirmation.isEmpty { savePasswordDraft() }
        if thresholdDirty { drafts.pendingSaves.insert(.threshold); applyThresholdDraft() }
        completeDraftSaveIfReady()
    }
    func completeDraftSaveIfReady() {
        var failure: String?
        for kind in Array(drafts.pendingSaves) {
            switch kind {
            case .tmdb:
                guard !model.tmdbTokenBusy else { continue }
                failure = model.tmdbTokenError
                if failure == nil && model.tmdbTokenConfigured { drafts.tmdbToken = "" } else if failure == nil { continue }
            case .map:
                guard !model.mapKeyBusy else { continue }
                failure = model.mapKeyError
                if failure == nil && model.mapKeyConfigured { drafts.tiandituKey = "" } else if failure == nil { continue }
            case .notification:
                guard !model.notifyBusy else { continue }
                failure = model.notifyError
                if failure == nil && model.notifyConfigured {
                    drafts.notificationBaseline = drafts.notification
                    drafts.notifyBarkKey = ""; drafts.notifySMTPPassword = ""; drafts.notifyDingtalkSecret = ""
                } else if failure == nil { continue }
            case .credentials:
                guard !model.verifyingAdmin else { continue }
                if model.administratorSaveSucceeded { drafts.vaultPassword = "" }
                else { failure = model.vaultMessage ?? "凭据尚未保存，请检查输入与服务状态。" }
            case .password:
                guard !model.resettingAdmin else { continue }
                if model.administratorResetSucceeded { drafts.resetAdminPassword = ""; drafts.resetAdminConfirmation = "" }
                else { failure = model.resetAdminMessage ?? "密码尚未更新，请完成设备验证。" }
            case .threshold:
                if thresholdDirty { continue }
            }
            drafts.pendingSaves.remove(kind)
            if let failure { drafts.draftError = failure; drafts.saveBeforeLeaving = false }
        }
        if let error = childEdits.error { drafts.draftError = error; drafts.saveBeforeLeaving = false; drafts.cancelTimeout() }
        if drafts.saveBeforeLeaving && drafts.pendingSaves.isEmpty && !childEdits.dirty && !childEdits.busy {
            drafts.saveBeforeLeaving = false
            if !hasUnsavedDrafts && drafts.draftError == nil { drafts.cancelTimeout(); finishNavigation() }
        }
    }
}
