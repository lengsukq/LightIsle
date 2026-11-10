import Foundation

/// Primary navigation and subordinate routes share one selection. Legacy
/// commands can still address files/photos/cinema/dependencies directly.
enum ManagementSection: String, CaseIterable, Identifiable {
    case overview = "概览", storage = "存储", services = "网络与连接"
    case containers = "Docker 与应用", spaces = "个人空间", settings = "设置"
    var id: Self { self }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .storage: return "externaldrive"
        case .services: return "network"
        case .containers: return "shippingbox"
        case .spaces: return "folder"
        case .settings: return "gearshape"
        }
    }
}
enum StorageDetail: String, CaseIterable, Identifiable {
    case disks = "磁盘设备", locations = "存储位置", capacity = "空间与告警"
    case trash = "回收站", backup = "配置备份与恢复", timeMachine = "Time Machine"
    var id: Self { self }
    var icon: String {
        switch self {
        case .disks: return "externaldrive"
        case .locations: return "folder.badge.gearshape"
        case .capacity: return "chart.bar"
        case .trash: return "trash"
        case .backup: return "clock.arrow.circlepath"
        case .timeMachine: return "clock.badge.checkmark"
        }
    }
    var subtitle: String {
        switch self {
        case .disks: return "挂载状态、容量及按需健康检查"
        case .locations: return "查看目录登记，连接或重新选择存储位置"
        case .capacity: return "查看可用空间并设置低空间提醒"
        case .trash: return "管理自动清理周期和保留规则"
        case .backup: return "每周保存应用配置，保留最近 5 份"
        case .timeMachine: return "核对原始文件的独立备份保护"
        }
    }
}
enum ConnectionDetail: String, CaseIterable, Identifiable {
    case local = "本机服务", lan = "局域网连接", sharing = "Mac 文件共享"
    case remote = "私人网络", cloudflare = "Cloudflare Tunnel", frp = "FRP"
    var id: Self { self }
    var icon: String {
        switch self {
        case .local: return "desktopcomputer"
        case .lan: return "wifi"
        case .sharing: return "externaldrive.connected.to.line.below"
        case .remote: return "network.badge.shield.half.filled"
        case .cloudflare: return "cloud"
        case .frp: return "point.topleft.down.curvedto.point.bottomright.up"
        }
    }
    var subtitle: String {
        switch self {
        case .local: return "核心服务状态与本机访问地址"
        case .lan: return "其他设备的连接地址与加密验证"
        case .sharing: return "由 macOS 管理的 SMB 文件共享"
        case .remote: return "通过自己的私人网络在外面访问"
        case .cloudflare: return "临时隧道、命名隧道及域名路由"
        case .frp: return "使用自己的服务端与本地配置"
        }
    }
}
enum DockerDetail: String, CaseIterable, Identifiable {
    case containers = "容器", compose = "Compose 项目", images = "镜像", resources = "卷与网络", mirrors = "镜像源"
    var id: Self { self }
    var icon: String {
        switch self {
        case .containers: return "shippingbox"
        case .compose: return "square.stack.3d.up"
        case .images: return "square.stack"
        case .resources: return "externaldrive.connected.to.line.below"
        case .mirrors: return "network"
        }
    }
}

/// A pure state machine makes cancellation, hand-off and pinning testable
/// without opening windows or relying on wall-clock timing.
struct DetailPreviewState {
    private(set) var owner: UUID?
    private(set) var pinned = false
    private(set) var generation = 0
    mutating func invalidateDelay() -> Int { generation += 1; return generation }
    mutating func show(_ id: UUID, ticket: Int) {
        guard ticket == generation, !pinned else { return }
        owner = id
    }
    mutating func pin(_ id: UUID) { generation += 1; owner = id; pinned = true }
    mutating func dismiss() { generation += 1; owner = nil; pinned = false }
    mutating func dismiss(ticket: Int) { if ticket == generation && !pinned { dismiss() } }
}

enum NativeFormValidation {
    static func threshold(gib: String, percent: String, priorMiB: Int, priorPercent: Int) -> (Int, Int)? {
        let rawGiB = gib.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPercent = percent.trimmingCharacters(in: .whitespacesAndNewlines)
        let free = rawGiB.isEmpty ? Double(priorMiB) / 1024 : Double(rawGiB)
        let fraction = rawPercent.isEmpty ? Double(priorPercent) : Double(rawPercent)
        guard let free, let fraction, free.isFinite, fraction.isFinite,
              free >= 0, free <= 1024, fraction >= 0, fraction <= 50, fraction == fraction.rounded() else { return nil }
        let miB = Int((free * 1024).rounded())
        let percentage = Int(fraction.rounded())
        guard miB > 0 || percentage > 0 else { return nil }
        return (miB, percentage)
    }
}

enum PreferencesSection: String, CaseIterable, Hashable, Identifiable {
    case general, media, notifications, security, tools, about
    var id: Self { self }
    var title: String {
        switch self {
        case .general: return "通用"
        case .media: return "媒体服务"
        case .notifications: return "通知"
        case .security: return "账号与安全"
        case .tools: return "工具"
        case .about: return "关于"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "登录启动、轻量模式及本机端口"
        case .media: return "媒体信息、照片地图与缩略图缓存"
        case .notifications: return "系统通知与外发通知渠道"
        case .security: return "管理员身份、密码与 Touch ID 保护"
        case .tools: return "外部依赖与按需高级诊断"
        case .about: return "版本信息与轻屿介绍"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .media: return "film"
        case .notifications: return "bell"
        case .security: return "lock.shield"
        case .tools: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}
enum SettingsTool { case diagnostics }
