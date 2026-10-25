import Foundation

/// Converts untrusted Cloudflare IPC JSON into typed domain data. The caller
/// retains control of UI state and follow-up requests (never triggered here).
struct TunnelPayloadSnapshot {
    let operation: String?
    let accounts: [TunnelAccount]?
    let zones: [TunnelZone]?
    let tunnels: [TunnelEntry]?
    let createdTunnel: TunnelEntry?
    let deleted: Bool
    let forgotten: Bool
    let ingress: [TunnelIngressRule]?
}

enum TunnelPayloadParser {
    private struct ConfigPayload: Decodable {
        let ingress: [TunnelIngressRule]
    }

    static func parse(_ payload: [String: Any]) -> TunnelPayloadSnapshot {
        let accounts: [TunnelAccount]? = decode(payload["accounts"])
        let zones: [TunnelZone]? = decode(payload["zones"])
        let tunnels: [TunnelEntry]? = decode(payload["tunnels"])
        let createdTunnel: TunnelEntry? = decode(payload["tunnel"])
        let config: ConfigPayload? = decode(payload["config"])
        return TunnelPayloadSnapshot(
            operation: payload["operation"] as? String,
            accounts: accounts,
            zones: zones?.filter { $0.status == "active" },
            tunnels: tunnels,
            createdTunnel: createdTunnel,
            deleted: payload["deleted"] != nil,
            forgotten: payload["forgotten"] as? Bool == true,
            ingress: config?.ingress
        )
    }

    private static func decode<T: Decodable>(_ value: Any?) -> T? {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
