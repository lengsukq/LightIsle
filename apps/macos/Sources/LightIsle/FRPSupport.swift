import Foundation

/// Only local Mac/Core IPC exposes the FRP controls; no browser-facing
/// endpoint is allowed to launch third-party executables.
struct FRPState: Decodable {
    let status: String
    let installed: Bool
    let version: String
    let installingVersion: String?
    let configPath: String
    let binaryPath: String
    let pid: Int?
    let error: String?
    let lastLine: String?

    var statusDescription: String {
        switch status {
        case "installing": return "正在下载安装…"
        case "starting": return "启动中…"
        case "running": return "正在运行"
        case "error": return "发生错误"
        default: return installed ? "已安装 · 未运行" : "未安装"
        }
    }
}

struct FRPRelease: Decodable, Identifiable, Equatable {
    let version: String
    let publishedAt: String?
    let prerelease: Bool
    let installable: Bool
    let reason: String?

    var id: String { version }
    var displayName: String {
        "v" + version + (prerelease ? " · 预发布" : "") +
            (!installable ? " · 不可安装" : "")
    }
    var reasonDescription: String? {
        switch reason {
        case "frpc_platform_unavailable": return "该版本未提供 macOS ARM64 文件。"
        case "frpc_checksum_unavailable": return "该版本缺少可验证的官方 SHA-256 摘要。"
        default: return nil
        }
    }
}
