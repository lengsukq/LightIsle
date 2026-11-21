import SwiftUI
import AppKit

extension ContentView {
    var personalSpacesView: some View {
        VStack(alignment: .leading, spacing: 18) {
            PersonalSpacesManagementView(appModel: model, spaces: model.personalSpaces)

            Text("快捷打开空间与模块详情").font(.system(size: 15, weight: .semibold)).padding(.top, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                LiquidSanctuaryTile(
                    title: "私人文件",
                    subtitle: model.sharedFolderPath == nil ? "存储待设置" : "当前目录：\(model.sharedFolderName)",
                    detail: "在浏览器中直接管理共享与私人文件",
                    icon: "folder",
                    badgeText: "直接打开"
                ) { model.openUserWeb(page: "files") }
                LiquidSanctuaryTile(
                    title: "时光相册",
                    subtitle: "缓存上限 \(thumbnailCacheMiB >= 1024 ? "\(thumbnailCacheMiB / 1024) GiB" : "\(thumbnailCacheMiB) MiB")",
                    detail: "浏览时间线、精选回忆与文件夹相册",
                    icon: "photo.on.rectangle",
                    badgeText: "直接打开"
                ) { model.openUserWeb(page: "photos") }
                LiquidSanctuaryTile(
                    title: "私人影院",
                    subtitle: "海报墙与多端续播",
                    detail: "浏览电影与剧集，支持原画直放与字幕",
                    icon: "film",
                    badgeText: "直接打开"
                ) { model.openUserWeb(page: "cinema") }
            }
            .disabled(model.state != .online)

            Text("日常浏览、上传与观影在独立的 Web 端或移动客户端中进行；Mac 管理端负责后台服务与存储。")
                .font(.system(size: 12.5)).foregroundStyle(IsleTheme.secondaryText).padding(.top, 4)
        }
    }
}
