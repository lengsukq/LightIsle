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
        return "tunnel api " + operation + " " + data.base64URLEncodedString
    }

    static func manualTokenCommand(_ token: String) throws -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...256).contains(trimmed.count) else { throw TunnelWireError.invalidRequest }
        let data = try JSONSerialization.data(withJSONObject: [
            "tunnelId": "manual", "tunnelName": "手动 Token", "token": trimmed
        ])
        guard data.count <= 16_384 else { throw TunnelWireError.invalidRequest }
        return "tunnel run " + data.base64URLEncodedString
    }

    static func decodeAPI(_ raw: String) -> [String: Any]? {
        guard let data = Data(base64URLEncoded: raw) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func decodeError(_ raw: String) -> String? {
        guard let data = Data(base64URLEncoded: raw) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
