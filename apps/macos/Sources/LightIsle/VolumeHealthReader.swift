import Foundation

struct VolumeHealthStatus: Sendable {
    let status: String
    let warning: Bool
    let protocolName: String?
}

/// Uses only macOS's built-in, read-only diskutil info -plist. This is never
/// invoked with administrator privileges, shell expansion or arbitrary
/// commands. Many USB/NVMe enclosures do not expose SMART, which must not be
/// mistaken for a verified healthy device.
enum VolumeHealthReader {
    static func readAll(_ mounts: [String]) -> [String: VolumeHealthStatus] {
        var result: [String: VolumeHealthStatus] = [:]
        for mount in mounts.prefix(32) where mount.hasPrefix("/") {
            result[mount] = inspect(mount)
        }
        return result
    }

    private static func inspect(_ mount: String) -> VolumeHealthStatus {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["info", "-plist", mount]
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        do {
            try task.run()
        } catch {
            return VolumeHealthStatus(status: "不可用（系统检测失败）", warning: false, protocolName: nil)
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            if task.isRunning { task.terminate() }
            return VolumeHealthStatus(status: "不可用（检测超时）", warning: false, protocolName: nil)
        }
        guard task.terminationStatus == 0 else {
            return VolumeHealthStatus(status: "不可用（设备未响应）", warning: false, protocolName: nil)
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= 2_000_000,
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return VolumeHealthStatus(status: "不可用（无法读取健康信息）", warning: false, protocolName: nil)
        }
        let raw = (values["SMARTStatus"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let protocolName = values["Protocol"] as? String
        switch raw?.lowercased() {
        case "verified":
            return VolumeHealthStatus(status: "已验证", warning: false, protocolName: protocolName)
        case "failing", "failure", "failed":
            return VolumeHealthStatus(status: "磁盘报告故障，请尽快备份", warning: true, protocolName: protocolName)
        case "not supported":
            return VolumeHealthStatus(status: "设备不支持读取", warning: false, protocolName: protocolName)
        default:
            return VolumeHealthStatus(status: raw?.isEmpty == false ? raw! : "设备未提供", warning: false, protocolName: protocolName)
        }
    }
}
