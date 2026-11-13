import Foundation

/// Typed, side-effect-free decoder for Core configuration notifications.
/// Invalid payloads still consume the wire event, but do not mutate settings.
enum CoreIPCSettingsEvent {
    case mapState(Bool?)
    case mapError
    case frpState(FRPState?)
    case frpVersions([FRPRelease]?)
    case frpError(String)
    case tmdbState(TmdbState?)
    case tmdbError(String?)

    static func decode(_ line: String) -> Self? {
        func json<T: Decodable>(_ type: T.Type, prefix: String) -> T? {
            let raw = String(line.dropFirst(prefix.count))
            return CoreIPCPayloadCodec.decodeJSON(type, raw: raw)
        }
        if line.hasPrefix("LIGHTISLE_MAP_STATE ") {
            return .mapState(json(MapServiceState.self, prefix: "LIGHTISLE_MAP_STATE ")?.configured)
        }
        if line.hasPrefix("LIGHTISLE_MAP_ERROR ") { return .mapError }
        if line.hasPrefix("LIGHTISLE_FRP_STATE ") {
            return .frpState(json(FRPState.self, prefix: "LIGHTISLE_FRP_STATE "))
        }
        if line.hasPrefix("LIGHTISLE_FRP_VERSIONS ") {
            return .frpVersions(json([FRPRelease].self, prefix: "LIGHTISLE_FRP_VERSIONS "))
        }
        if line.hasPrefix("LIGHTISLE_FRP_ERROR ") {
            let raw = String(line.dropFirst("LIGHTISLE_FRP_ERROR ".count))
            return .frpError(TunnelWireCodec.decodeError(raw) ?? "FRP 操作失败")
        }
        if line.hasPrefix("LIGHTISLE_TMDB_STATE ") {
            return .tmdbState(json(TmdbState.self, prefix: "LIGHTISLE_TMDB_STATE "))
        }
        if line.hasPrefix("LIGHTISLE_TMDB_ERROR ") {
            let raw = String(line.dropFirst("LIGHTISLE_TMDB_ERROR ".count))
            return .tmdbError(CoreIPCPayloadCodec.decodeText(raw))
        }
        return nil
    }
}

/// The Core protocol uses URL-safe unpadded Base64 for JSON and diagnostic
/// strings. Keep this conversion in a single bounded, pure codec.
enum CoreIPCPayloadCodec {
    static func decodeJSON<T: Decodable>(_ type: T.Type, raw: String) -> T? {
        guard let data = Data(base64URLEncoded: raw) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func decodeText(_ raw: String) -> String? {
        guard let data = Data(base64URLEncoded: raw) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
