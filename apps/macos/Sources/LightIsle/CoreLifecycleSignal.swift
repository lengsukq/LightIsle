import Foundation

/// Parses the subset of trusted native Core lines that affect service
/// lifecycle. The ready URL is accepted only from the loopback HTTP endpoint;
/// public endpoints and malformed values never initialize the native UI.
enum CoreLifecycleSignal: Equatable {
    case remoteOff
    case remoteError(String)
    case ready(URL)
    case serviceWarning(String)

    static func decode(_ line: String) -> CoreLifecycleSignal? {
        if line == "LIGHTISLE_REMOTE_OFF" { return .remoteOff }
        if line.hasPrefix("LIGHTISLE_REMOTE_ERROR ") {
            return .remoteError(String(line.dropFirst("LIGHTISLE_REMOTE_ERROR ".count)))
        }
        switch line {
        case "LIGHTISLE_SERVICE_WARNING task_history":
            return .serviceWarning("任务历史和运行告警暂不可用。文件仍可访问，请检查 Mac 上的任务数据库。")
        case "LIGHTISLE_SERVICE_WARNING backup_schedule":
            return .serviceWarning("每周配置备份已暂停。手动备份仍可用，请检查 Mac 上的备份计划文件。")
        default: break
        }
        guard line.hasPrefix("LIGHTISLE_READY ") else { return nil }
        let raw = String(line.dropFirst("LIGHTISLE_READY ".count))
        guard let url = URL(string: raw),
              url.scheme == "http", url.host == "127.0.0.1",
              let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        return .ready(url)
    }
}
