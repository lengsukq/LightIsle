import SwiftUI

enum SidebarPage: String, CaseIterable, Hashable {
    case overview = "概览"
    case files = "私人文件"
    case photos = "时光相册"
    case cinema = "私人影院"
    case spaces = "个人空间"
    case containers = "Docker 与应用"
    case dependencies = "外部依赖"
    case services = "网络与连接"
    case storage = "存储"
    case settings = "设置"

    var icon: String {
        switch self {
        case .overview: return "house.fill"
        case .files: return "folder.fill"
        case .photos: return "photo.stack.fill"
        case .cinema: return "film"
        case .spaces: return "folder"
        case .containers: return "shippingbox.fill"
        case .dependencies: return "shippingbox.circle.fill"
        case .services: return "network"
        case .storage: return "externaldrive.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .overview: return "1"
        case .files: return "2"
        case .photos: return "3"
        case .cinema: return "4"
        case .spaces: return "0"
        case .containers: return "8"
        case .dependencies: return "9"
        case .services: return "5"
        case .storage: return "6"
        case .settings: return "7"
        }
    }

    var section: ManagementSection {
        switch self {
        case .overview: return .overview
        case .storage: return .storage
        case .services: return .services
        case .containers: return .containers
        case .spaces, .files, .photos, .cinema: return .spaces
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
        case .spaces: return "在自己的设备之间访问文件、照片与影院"
        case .files: return "浏览和管理已授权的共享文件目录"
        case .photos: return "浏览共享目录中的照片和视频，并查看媒体预览"
        case .cinema: return "浏览媒体库并播放当前设备支持的视频"
        case .containers: return "管理本机 Docker/Colima 容器与镜像加速源"
        case .dependencies: return "查看并按需安装媒体、下载、健康检测与网络工具"
        case .services: return "查看本机服务、网络连接和文件共享设置"
        case .storage: return "查看存储用量、共享目录以及备份与恢复状态"
        case .settings: return "管理管理员账户、安全选项和应用偏好"
        }
    }

}
