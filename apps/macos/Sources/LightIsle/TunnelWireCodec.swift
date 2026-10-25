import Foundation

enum TunnelWireError: Error {
    case invalidOperation
    case invalidRequest
}

/// Trusted Mac App / Go Core pipe contract. All remote API commands use the
/// same bounded, URL-safe base64 JSON encoding; tokens never enter logs.
enum TunnelWireCodec {
    private static let supportedOperations: Set<String> = [
        "configure", "accounts", "zones", "tunnels", "create", "delete",
        "config", "route", "route-remove", "token", "forget"
    ]

    static func apiCommand(operation: String, payload: [String: Any]) throws -> String {
        guard supportedOperations.contains(operation) else { throw TunnelWireError.invalidOperation }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard !data.isEmpty && data.count <= 16_384 else { throw TunnelWireError.invalidRequest }
        return "tunnel api " + operation + " " + base64URL(data)
    }

    static func manualTokenCommand(_ token: String) throws -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...256).contains(trimmed.count) else { throw TunnelWireError.invalidRequest }
        let data = try JSONSerialization.data(withJSONObject: [
            "tunnelId": "manual", "tunnelName": "手动 Token", "token": trimmed
        ])
        guard data.count <= 16_384 else { throw TunnelWireError.invalidRequest }
        return "tunnel run " + base64URL(data)
    }

    static func decodeAPI(_ raw: String) -> [String: Any]? {
        guard let data = decodeData(raw) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func decodeError(_ raw: String) -> String? {
        guard let data = decodeData(raw) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeData(_ raw: String) -> Data? {
        var normalized = raw.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
