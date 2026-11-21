import AppKit
import Foundation

/// Single source of truth for writing plain text to the macOS general pasteboard.
@MainActor
enum PasteboardHelper {
    @discardableResult
    static func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
