import Foundation

/// Parses the subset of trusted native Core lines that affect service
/// lifecycle. The ready URL is accepted only from the loopback HTTP endpoint;
/// public endpoints and malformed values never initialize the native UI.
enum CoreLifecycleSignal: Equatable {
    case remoteOff
    case remoteError(String)
    case ready(URL)

    static func decode(_ line: String) -> CoreLifecycleSignal? {
        if line == "LIGHTISLE_REMOTE_OFF" { return .remoteOff }
        if line.hasPrefix("LIGHTISLE_REMOTE_ERROR ") {
            return .remoteError(String(line.dropFirst("LIGHTISLE_REMOTE_ERROR ".count)))
        }
        guard line.hasPrefix("LIGHTISLE_READY ") else { return nil }
        let raw = String(line.dropFirst("LIGHTISLE_READY ".count))
        guard let url = URL(string: raw),
              url.scheme == "http", url.host == "127.0.0.1" else { return nil }
        return .ready(url)
    }
}
