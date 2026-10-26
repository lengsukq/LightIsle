import Foundation

/// Advertises the selected LAN listener, but does not expose a new listener.
/// Never publishes credentials or grants access outside the configured LAN.
@MainActor
final class BonjourPublisher: NSObject, @preconcurrency NetServiceDelegate {
    private var service: NetService?
    private var currentEndpoint: String?
    var onStatusChange: ((String) -> Void)?

    func update(port: Int?, scheme: String?) {
        let endpoint = port.flatMap { port in scheme.map { "\($0):\(port)" } }
        guard endpoint != currentEndpoint else { return }
        stop()
        guard let port, (1...65535).contains(port),
              let scheme, ["http", "https"].contains(scheme) else { return }
        currentEndpoint = endpoint
        let name = "LightIsle-\(Host.current().localizedName ?? "Mac")"
        let candidate = NetService(domain: "local.", type: "_lightisle._tcp.", name: name, port: Int32(port))
        candidate.setTXTRecord(NetService.data(fromTXTRecord: ["scheme": Data(scheme.utf8)]))
        candidate.delegate = self
        service = candidate
        candidate.publish()
        onStatusChange?("正在广播…")
    }

    func stop() {
        service?.stop()
        service?.delegate = nil
        service = nil
        currentEndpoint = nil
        onStatusChange?("未广播（局域网服务已关闭或未就绪）")
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard sender === service else { return }
        onStatusChange?("已广播 _lightisle._tcp · \(sender.name)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === service else { return }
        stop()
        onStatusChange?("Bonjour 广播失败，请检查本地网络权限")
    }
}
