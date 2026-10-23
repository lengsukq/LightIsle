import Foundation

/// Advertises the existing HTTPS listener, but does not expose a new listener.
/// Never publishes credentials or grants access outside the configured LAN.
@MainActor
final class BonjourPublisher: NSObject, @preconcurrency NetServiceDelegate {
    private var service: NetService?
    private var currentPort: Int?
    var onStatusChange: ((String) -> Void)?

    func update(httpsPort: Int?) {
        guard httpsPort != currentPort else { return }
        stop()
        guard let httpsPort, (1...65535).contains(httpsPort) else { return }
        currentPort = httpsPort
        let name = "LightIsle-\(Host.current().localizedName ?? "Mac")"
        let candidate = NetService(domain: "local.", type: "_lightisle._tcp.", name: name, port: Int32(httpsPort))
        candidate.delegate = self
        service = candidate
        candidate.publish()
        onStatusChange?("正在广播…")
    }

    func stop() {
        service?.stop()
        service?.delegate = nil
        service = nil
        currentPort = nil
        onStatusChange?("未广播（局域网 HTTPS 已关闭或服务未就绪）")
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
