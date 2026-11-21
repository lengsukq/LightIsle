import SwiftUI

enum SidebarPage: String, CaseIterable, Hashable {
    case overview = "概览"
    case storage = "存储"
    case services = "网络与连接"
    case containers = "Docker 与应用"
    case spaces = "个人空间"
    case settings = "设置"
    case dependencies = "外部依赖"

    var icon: String {
        switch self {
        case .overview: return "house.fill"
        case .storage: return "externaldrive.fill"
        case .services: return "network"
        case .containers: return "shippingbox.fill"
        case .spaces: return "folder"
        case .settings: return "gearshape.fill"
        case .dependencies: return "shippingbox.circle.fill"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .overview: return "1"
        case .storage: return "2"
        case .services: return "3"
        case .containers: return "4"
        case .spaces: return "5"
        case .settings: return "6"
        case .dependencies: return "7"
        }
    }

    var section: ManagementSection {
        switch self {
        case .overview: return .overview
        case .storage: return .storage
        case .services: return .services
        case .containers: return .containers
        case .spaces: return .spaces
        case .settings, .dependencies: return .settings
        }
    }
    static func primary(_ section: ManagementSection) -> SidebarPage {
        switch section {
        case .overview: return .overview
        case .storage: return .storage
        case .services: return .services
        case .containers: return .containers
        case .spaces: return .spaces
        case .settings: return .settings
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "服务、存储与需要处理的事项"
        case .storage: return "查看存储用量、共享目录以及备份与恢复状态"
        case .services: return "查看本机服务、网络连接和文件共享设置"
        case .containers: return "管理轻应用与本机 Docker/Colima 容器"
        case .spaces: return "在自己的设备之间访问文件、照片与影院"
        case .settings: return "管理管理员账户、安全选项和应用偏好"
        case .dependencies: return "查看并按需安装媒体、下载、健康检测与网络工具"
        }
    }

}
