import Foundation

enum TunnelCredentialOutcome {
    case saved
    case unchanged(savedLocally: Bool)
    case failed(savedLocally: Bool, reason: String)
}

/// Keeps a newly submitted API token ephemeral until Core verifies it.
/// The persistence adapter is injected for independent failure testing.
@MainActor
final class TunnelCredentialCoordinator {
    private let save: (String) throws -> Void
    private let load: () -> String?
    private let remove: () throws -> Void
    private var pending: String?

    init(save: @escaping (String) throws -> Void,
         load: @escaping () -> String?,
         remove: @escaping () throws -> Void) {
        self.save = save
        self.load = load
        self.remove = remove
    }

    func stage(_ token: String) { pending = token }
    func cancelPending() { pending = nil }
    func storedToken() -> String? { load() }

    func forget() throws {
        defer { pending = nil }
        try remove()
    }

    func didValidateAccounts() -> TunnelCredentialOutcome {
        guard let token = pending else {
            return .unchanged(savedLocally: load() != nil)
        }
        // Always release plaintext after a response, even on Keychain error.
        defer { pending = nil }
        do {
            try save(token)
            return .saved
        } catch {
            // The old credential was not deleted prior to the failed save.
            return .failed(savedLocally: load() != nil, reason: error.localizedDescription)
        }
    }
}
