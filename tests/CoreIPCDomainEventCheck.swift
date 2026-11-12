import Foundation

@main
struct CoreIPCDomainEventCheck {
    static func main() {
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_COMPUTER_FILES 1") == .computerFiles(.state(true)))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_COMPUTER_FILES 0") == .computerFiles(.state(false)))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_COMPUTER_FILES_ERROR") == .computerFiles(.error))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_ROOTS eyJ9") == .subsystem(.roots("eyJ9")))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_SPACES eyJ9") == .subsystem(.spaces("eyJ9")))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_APPS eyJ9") == .subsystem(.apps("eyJ9")))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_EXPORT_STARTED") == .export(.started))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_EXPORT_OK cGF0aA") == .export(.succeeded("cGF0aA")))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_ADMIN_VERIFIED") == .admin(.verified))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_ADMIN_RESET_ERROR invalid_password") == .admin(.resetFailed("invalid_password")))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_NOTIFY_ON") == .notify(.enabled))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_BACKUP_STARTED") == .backup(.started))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_SMB_STATUS 1") == .smb(.listening(true)))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_CONFIGURED 1") == .setup(.configured(true)))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_REMOTE_ON lan-endpoint fp123") == .remoteOn(address: "lan-endpoint", fingerprint: "fp123"))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_REMOTE_ON lan-endpoint -") == .remoteOn(address: "lan-endpoint", fingerprint: nil))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_SHARE_ACCESS_REVOKED 1") == .legacyShare(.accessRevoked(true)))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_SHARE_ACCESS_REVOKED 0") == .legacyShare(.accessRevoked(false)))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_SHARE_ACCESS_REVOKED unknown") == .legacyShare(.accessRevoked(nil)))
        precondition(CoreIPCDomainEvent.decode("LIGHTISLE_UNKNOWN_LINE") == nil)

        precondition(CoreIPCDomainMessages.adminResetError(for: "invalid_password").contains("长度或格式"))
        precondition(CoreIPCDomainMessages.initError(for: "already_configured").alreadyConfigured == true)
        precondition(CoreIPCDomainMessages.shareForgetErrorMessage(for: "shared_directory_transition_busy").contains("稍后重试"))
        precondition(CoreIPCDomainMessages.pendingStorageSelectionErrorMessage(for: "root_registry_overlap").contains("重叠"))
        print("PASS: CoreIPCDomainEvent wire decoding and error mapping checks")
    }
}
