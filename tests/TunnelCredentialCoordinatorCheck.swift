import Foundation

private enum TestKeychainFailure: LocalizedError {
    case locked
    var errorDescription: String? { "keychain-locked" }
}

@main
struct TunnelCredentialCoordinatorCheck {
    @MainActor
    static func main() {
        var saved: String? = "previous-credential"
        var shouldFail = false
        var removalShouldFail = false
        let credentials = TunnelCredentialCoordinator(
            save: { token in
                if shouldFail { throw TestKeychainFailure.locked }
                saved = token
            },
            load: { saved },
            remove: {
                if removalShouldFail { throw TestKeychainFailure.locked }
                saved = nil
            }
        )
        credentials.stage("replacement")
        shouldFail = true
        switch credentials.didValidateAccounts() {
        case .failed(let stored, let reason):
            precondition(stored && reason.contains("keychain-locked"))
        default:
            fatalError("failed Keychain write must not appear successful")
        }
        precondition(saved == "previous-credential")
        shouldFail = false
        switch credentials.didValidateAccounts() {
        case .unchanged(let stored): precondition(stored)
        default: fatalError("failed staged token must have been cleared")
        }
        credentials.stage("new-credential")
        switch credentials.didValidateAccounts() {
        case .saved: break
        default: fatalError("validated replacement must be persisted")
        }
        precondition(saved == "new-credential")
        credentials.stage("unverified-token")
        credentials.cancelPending()
        _ = credentials.didValidateAccounts()
        precondition(saved == "new-credential")
        removalShouldFail = true
        do {
            try credentials.forget()
            fatalError("Keychain removal failure must remain visible")
        } catch TestKeychainFailure.locked {
            // The prior credential must survive a locked login Keychain.
        } catch {
            fatalError("unexpected removal error: \(error)")
        }
        precondition(saved == "new-credential")
        removalShouldFail = false
        try? credentials.forget()
        precondition(credentials.storedToken() == nil)
        print("PASS: tunnel credential lifecycle protects the prior token and rejects unverified writes")
    }
}
