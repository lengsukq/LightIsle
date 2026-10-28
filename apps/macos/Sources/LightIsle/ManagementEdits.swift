import SwiftUI

/// A page can protect local drafts without moving credentials or Docker state
/// into the global app model. Closures are released when the page disappears.
@MainActor
final class ManagementEdits: ObservableObject {
    @Published var dirty = false
    @Published var busy = false
    @Published var error: String?
    var save: (() -> Void)?
    var discard: (() -> Void)?
    func reset() { dirty = false; busy = false; error = nil; save = nil; discard = nil }
}

struct NativeSaveSignal: Equatable {
    let pending: [Bool]
    let messages: [String?]
    let threshold: [Int?]
    let trashDays: Int
    let trashEnabled: Bool
}
