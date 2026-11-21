import Foundation

/// Probes only the parent-owned loopback listener, independent of disk and
/// optional IPC operations. Never follows a redirect or uses a system proxy.
final class CoreHealthProbe: Sendable {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func check(_ endpoint: URL) async -> Bool {
        let url = endpoint.appendingPathComponent("api/v2/health")
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            var body = Data()
            for try await byte in bytes {
                guard body.count < 4096 else { return false }
                body.append(byte)
            }
            let value = try JSONDecoder().decode(Health.self, from: body)
            return value.status == "ok" && value.application == "LightIsle"
        } catch {
            return false
        }
    }

    func close() { session.invalidateAndCancel() }

    deinit { session.invalidateAndCancel() }

    private struct Health: Decodable {
        let status: String
        let application: String
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
