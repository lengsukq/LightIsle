import Foundation

// MARK: - IPC payload models (mirroring the Go tunnel package)

struct TunnelState: Decodable, Equatable {
    let mode: String
    let status: String
    let url: String?
    let tunnelId: String?
    let tunnelName: String?
    let binary: String?
    let binaryFound: Bool
    let pid: Int?
    let error: String?
    let lastLine: String?

    var statusDescription: String {
        switch status {
        case "online": return "在线"
        case "starting": return "启动中…"
        case "error": return "异常"
        default: return "已停止"
        }
    }
}

struct TunnelEntry: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String
    let connections: Int
    let remoteConfig: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case connections = "conns_active"
        case configSource = "config_src"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(String.self, forKey: .status)
        connections = (try? container.decode(Int.self, forKey: .connections)) ?? 0
        let source = (try? container.decode(String.self, forKey: .configSource)) ?? ""
        remoteConfig = source == "cloudflare"
    }
}

struct TunnelAccount: Decodable, Identifiable {
    let id: String
    let name: String
}

struct TunnelZone: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String
}

struct TunnelIngressRule: Codable, Identifiable, Equatable {
    let hostname: String?
    let service: String

    var id: String { (hostname ?? "（全部请求）") + " → " + service }
    var isCatchAll: Bool { hostname == nil || hostname?.isEmpty == true }
}
