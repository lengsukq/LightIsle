import Foundation

/// Only local Mac/Core IPC exposes the FRP controls; no browser-facing
/// endpoint is allowed to launch third-party executables.
struct FRPState: Decodable {
    let status: String
    let connection: String?
    let proxyCount: Int?
    let proxyReady: Int?
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
        case "restarting": return "连接意外中断 · 正在限次重试"
        case "running":
            switch connection {
            case "connected": return (proxyReady ?? 0) > 0 ? "服务端已连接 · 代理已注册" : "服务端已连接 · 代理待就绪"
            case "degraded": return "服务端已连接 · 代理异常"
            case "failed": return "连接失败 · 等待重试"
            case "unverified": return "客户端运行中 · 连接尚未验证"
            case "connecting": return "客户端已启动 · 正在连接服务端"
            default: return "客户端运行中 · 连接状态未确认"
            }
        case "error": return "发生错误"
        default: return installed ? "已安装 · 未运行" : "未安装"
        }
    }

    var connectionConfirmed: Bool {
        status == "running" && connection == "connected" && (proxyReady ?? 0) > 0
    }

    var connectionDescription: String {
        if status == "restarting" {
            return "frpc 意外退出，LightIsle 正在延时重启；可点击「停止」取消。重新启动客户端不代表远程代理已恢复。"
        }
        guard status == "running" else { return "客户端未运行，无法确认远程访问" }
        if connection == "connected", (proxyCount ?? 0) > 0 {
            return "已注册 \(proxyReady ?? 0)/\(proxyCount ?? 0) 条代理。外网访问仍需从其他网络验证。"
        }
        if connection == "degraded" { return "部分代理没有注册成功，请检查规则及服务端日志。" }
        if connection == "failed" { return "尚未建立可用连接。frpc 进程存在不代表穿透已成功。" }
        if connection == "unverified" { return "未收到明确的登录成功或代理注册结果，不能据此判断穿透已成功。" }
        return "等待 frps 登录与代理注册结果，进程启动并不代表连接成功。"
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
        "v" + version + (prerelease ? " · 预发布" : "")
    }
    var reasonDescription: String? {
        switch reason {
        case "frpc_platform_unavailable": return "该版本未提供 macOS ARM64 文件。"
        case "frpc_checksum_unavailable": return "该版本缺少可验证的官方 SHA-256 摘要。"
        default: return nil
        }
    }
}
