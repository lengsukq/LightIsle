import Foundation
import SwiftUI

/// Domain-scoped store for unsaved form drafts across settings, media services,
/// outbound notifications, administrator security, local port, storage threshold,
/// and manual tunnel token. Extracted from `ContentView` to eliminate `@State` sprawl.
@MainActor
final class PreferencesDraftStore: ObservableObject {
    // Media & Tunnel drafts
    @Published var tmdbToken = ""
    @Published var tiandituKey = ""
    @Published var manualTunnelToken = ""

    // Notification drafts
    @Published var notificationLoaded = false
    @Published var notification = NotificationDraft()
    @Published var notificationBaseline = NotificationDraft()
    @Published var notifyBarkKey = ""
    @Published var notifyDingtalkSecret = ""
    @Published var notifySMTPPassword = ""

    // Administrator & Security drafts
    @Published var vaultUsername = ""
    @Published var vaultPassword = ""
    @Published var resetAdminPassword = ""
    @Published var resetAdminConfirmation = ""

    // Host port & Storage alert threshold drafts
    @Published var localPortText = ""
    @Published var thresholdFreeMiBText = ""
    @Published var thresholdPercentText = ""

    // Save coordination state
    @Published var saveBeforeLeaving = false
    @Published var draftError: String?
    @Published var pendingSaves: Set<NativeDraft> = []
    var draftTimeout: Task<Void, Never>?

    var isNotificationDirty: Bool {
        notificationLoaded && (
            notification != notificationBaseline
                || !notifyBarkKey.isEmpty
                || !notifySMTPPassword.isEmpty
                || !notifyDingtalkSecret.isEmpty
        )
    }

    func isThresholdDirty(current: StorageThreshold?) -> Bool {
        guard let value = current else {
            return !thresholdFreeMiBText.isEmpty || !thresholdPercentText.isEmpty
        }
        guard let (miB, percent) = NativeFormValidation.threshold(
            gib: thresholdFreeMiBText,
            percent: thresholdPercentText,
            priorMiB: value.freeMiB,
            priorPercent: value.percent
        ) else {
            return !thresholdFreeMiBText.isEmpty || !thresholdPercentText.isEmpty
        }
        return miB != value.freeMiB || percent != value.percent
    }

    func hasUnsavedChanges(
        childDirty: Bool,
        preferredLocalPort: Int,
        storageThreshold: StorageThreshold?
    ) -> Bool {
        childDirty
            || !tmdbToken.isEmpty
            || !tiandituKey.isEmpty
            || isNotificationDirty
            || !vaultPassword.isEmpty
            || !resetAdminPassword.isEmpty
            || !resetAdminConfirmation.isEmpty
            || !manualTunnelToken.isEmpty
            || (!localPortText.isEmpty && localPortText != String(preferredLocalPort))
            || isThresholdDirty(current: storageThreshold)
    }

    func resetNotification() {
        notification = notificationBaseline
        notifyBarkKey = ""
        notifySMTPPassword = ""
        notifyDingtalkSecret = ""
    }

    func discardAll(preferredLocalPort: Int, discardChild: (() -> Void)?) {
        discardChild?()
        tmdbToken = ""
        tiandituKey = ""
        vaultUsername = ""
        vaultPassword = ""
        resetAdminPassword = ""
        resetAdminConfirmation = ""
        manualTunnelToken = ""
        localPortText = String(preferredLocalPort)
        thresholdFreeMiBText = ""
        thresholdPercentText = ""
        resetNotification()
        draftError = nil
    }

    func cancelTimeout() {
        draftTimeout?.cancel()
        draftTimeout = nil
    }
}
