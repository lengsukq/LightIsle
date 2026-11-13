import SwiftUI

enum NativeDraft: Hashable { case tmdb, map, notification, credentials, password, threshold }

extension ContentView {
    var draftSaveSignal: NativeSaveSignal {
        NativeSaveSignal(pending: [model.tmdbTokenBusy, model.mapKeyBusy, model.notifyBusy, model.verifyingAdmin,
                                   model.resettingAdmin, childEdits.dirty, childEdits.busy,
                                   model.administratorSaveSucceeded, model.administratorResetSucceeded],
                         messages: [model.tmdbTokenError, model.mapKeyError, model.notifyError, model.vaultMessage,
                                    model.resetAdminMessage, childEdits.error],
                         threshold: [model.storageThreshold?.freeMiB, model.storageThreshold?.percent])
    }

    var notificationFields: [String] {
        [notifyBarkServerDraft, notifyWebhookDraft, String(notifyAllowPrivateDraft), notifyWecomDraft, notifyDingtalkDraft,
         notifySMTPHostDraft, notifySMTPPortDraft, notifySMTPUserDraft, notifySMTPFromDraft, notifySMTPToDraft]
    }
    var notificationDirty: Bool {
        notificationDraftLoaded && (notificationFields != notificationBaseline || !notifyBarkKeyDraft.isEmpty || !notifySMTPPasswordDraft.isEmpty || !notifyDingtalkSecretDraft.isEmpty)
    }
    var thresholdDirty: Bool {
        guard let value = model.storageThreshold else { return !thresholdFreeMiBText.isEmpty || !thresholdPercentText.isEmpty }
        guard let (miB, percent) = NativeFormValidation.threshold(gib: thresholdFreeMiBText, percent: thresholdPercentText, priorMiB: value.freeMiB, priorPercent: value.percent) else {
            return !thresholdFreeMiBText.isEmpty || !thresholdPercentText.isEmpty
        }
        return miB != value.freeMiB || percent != value.percent
    }
    var hasUnsavedDrafts: Bool {
        childEdits.dirty || !tmdbTokenDraft.isEmpty || !tiandituKeyDraft.isEmpty || notificationDirty || !vaultPassword.isEmpty || !resetAdminPassword.isEmpty
            || !resetAdminConfirmation.isEmpty || !manualTunnelToken.isEmpty
            || (!localPortText.isEmpty && localPortText != String(model.preferredLocalPort))
            || thresholdDirty
    }
    func resetNotificationDraft() {
        let fields = notificationBaseline
        if fields.count == 10 {
            notifyBarkServerDraft = fields[0]; notifyWebhookDraft = fields[1]; notifyAllowPrivateDraft = fields[2] == "true"
            notifyWecomDraft = fields[3]; notifyDingtalkDraft = fields[4]; notifySMTPHostDraft = fields[5]
            notifySMTPPortDraft = fields[6]; notifySMTPUserDraft = fields[7]; notifySMTPFromDraft = fields[8]; notifySMTPToDraft = fields[9]
        }
        notifyBarkKeyDraft = ""; notifySMTPPasswordDraft = ""; notifyDingtalkSecretDraft = ""
    }
    func discardDrafts() {
        childEdits.discard?()
        tmdbTokenDraft = ""; tiandituKeyDraft = ""; vaultUsername = ""; vaultPassword = ""
        resetAdminPassword = ""; resetAdminConfirmation = ""; manualTunnelToken = ""
        localPortText = String(model.preferredLocalPort)
        thresholdFreeMiBText = ""; thresholdPercentText = ""
        resetNotificationDraft(); draftError = nil
    }
    func saveMediaDraft(_ kind: NativeDraft) {
        pendingDraftSaves.insert(kind)
        if kind == .tmdb { model.configureTmdbToken(tmdbTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)) }
        else { model.configureMapKey(tiandituKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)) }
        completeDraftSaveIfReady()
    }
    func saveNotificationDraft() {
        pendingDraftSaves.insert(.notification)
                            let savedBarkKey = notifyBarkKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            let prior = NotifySecretVault.load()
                            let smtpHost = notifySMTPHostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            model.configureNotify(NotifyChannelConfig(
                                barkServer: notifyBarkServerDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                barkKey: savedBarkKey.isEmpty && prior != nil ? prior!.barkKey : savedBarkKey,
                                webhookURL: notifyWebhookDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                allowPrivateTargets: notifyAllowPrivateDraft,
                                smtpHost: smtpHost.isEmpty ? nil : smtpHost,
                                smtpPort: smtpHost.isEmpty ? nil : (Int(notifySMTPPortDraft) ?? 465),
                                smtpUsername: smtpHost.isEmpty ? nil : notifySMTPUserDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                smtpPassword: smtpHost.isEmpty ? nil : (notifySMTPPasswordDraft.isEmpty ? prior?.smtpPassword : notifySMTPPasswordDraft),
                                smtpFrom: smtpHost.isEmpty ? nil : notifySMTPFromDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                smtpTo: smtpHost.isEmpty ? nil : notifySMTPToDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                wecomWebhook: notifyWecomDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                dingtalkWebhook: notifyDingtalkDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                dingtalkSecret: notifyDingtalkSecretDraft.isEmpty ? prior?.dingtalkSecret : notifyDingtalkSecretDraft
                            ))

        completeDraftSaveIfReady()
    }
    func saveCredentialDraft() {
        pendingDraftSaves.insert(.credentials)
        model.saveAdministratorWithTouchID(username: vaultUsername, password: vaultPassword)
        completeDraftSaveIfReady()
    }
    func savePasswordDraft() {
        guard resetAdminPassword == resetAdminConfirmation else { draftError = "两次输入的新密码不同，请核对后保存。"; return }
        pendingDraftSaves.insert(.password)
        model.resetAdministratorPassword(newPassword: resetAdminPassword)
        completeDraftSaveIfReady()
    }
    func saveDraftsAndLeave() {
        draftError = nil
        // Running a tunnel is a separate consequential action, not saving a form.
        guard manualTunnelToken.isEmpty else {
            draftError = "隧道 Token 尚未使用。请在当前页面选择启动，或放弃输入后离开。"; return
        }
        if !localPortText.isEmpty, localPortText != String(model.preferredLocalPort), !model.saveLocalPort(localPortText) {
            draftError = model.portError; return
        }
        saveBeforeLeaving = true
        draftTimeout?.cancel()
        draftTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, saveBeforeLeaving else { return }
            saveBeforeLeaving = false
            draftError = "尚未收到完整保存结果，输入已保留。请检查服务状态后重试。"
        }
        if childEdits.dirty { childEdits.save?() }
        if !tmdbTokenDraft.isEmpty { saveMediaDraft(.tmdb) }
        if !tiandituKeyDraft.isEmpty { saveMediaDraft(.map) }
        if notificationDirty { saveNotificationDraft() }
        if !vaultPassword.isEmpty { saveCredentialDraft() }
        if !resetAdminPassword.isEmpty || !resetAdminConfirmation.isEmpty { savePasswordDraft() }
        if thresholdDirty { pendingDraftSaves.insert(.threshold); applyThresholdDraft() }
        completeDraftSaveIfReady()
    }
    func completeDraftSaveIfReady() {
        var failure: String?
        for kind in Array(pendingDraftSaves) {
            switch kind {
            case .tmdb:
                guard !model.tmdbTokenBusy else { continue }
                failure = model.tmdbTokenError
                if failure == nil && model.tmdbTokenConfigured { tmdbTokenDraft = "" } else if failure == nil { continue }
            case .map:
                guard !model.mapKeyBusy else { continue }
                failure = model.mapKeyError
                if failure == nil && model.mapKeyConfigured { tiandituKeyDraft = "" } else if failure == nil { continue }
            case .notification:
                guard !model.notifyBusy else { continue }
                failure = model.notifyError
                if failure == nil && model.notifyConfigured {
                    notificationBaseline = notificationFields
                    notifyBarkKeyDraft = ""; notifySMTPPasswordDraft = ""; notifyDingtalkSecretDraft = ""
                } else if failure == nil { continue }
            case .credentials:
                guard !model.verifyingAdmin else { continue }
                if model.administratorSaveSucceeded { vaultPassword = "" }
                else { failure = model.vaultMessage ?? "凭据尚未保存，请检查输入与服务状态。" }
            case .password:
                guard !model.resettingAdmin else { continue }
                if model.administratorResetSucceeded { resetAdminPassword = ""; resetAdminConfirmation = "" }
                else { failure = model.resetAdminMessage ?? "密码尚未更新，请完成设备验证。" }
            case .threshold:
                if thresholdDirty { continue }
            }
            pendingDraftSaves.remove(kind)
            if let failure { draftError = failure; saveBeforeLeaving = false }
        }
        if let error = childEdits.error { draftError = error; saveBeforeLeaving = false; draftTimeout?.cancel() }
        if saveBeforeLeaving && pendingDraftSaves.isEmpty && !childEdits.dirty && !childEdits.busy {
            saveBeforeLeaving = false
            if !hasUnsavedDrafts && draftError == nil { draftTimeout?.cancel(); finishNavigation() }
        }
    }
}
