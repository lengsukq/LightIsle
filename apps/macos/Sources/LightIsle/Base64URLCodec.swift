import Foundation

/// Shared RFC 4648 §5 URL-safe unpadded Base64 helpers for Go Core / macOS IPC.
extension Data {
    init?(base64URLEncoded raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = trimmed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder == 1 {
            return nil
        }
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: normalized)
    }

    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
