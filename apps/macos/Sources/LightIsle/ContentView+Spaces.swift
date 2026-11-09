import SwiftUI
import AppKit

extension ContentView {
    var personalSpacesView: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                LiquidSanctuaryTile(
                    title: "私人文件",
                    subtitle: model.sharedFolderPath == nil ? "存储待设置" : "当前目录：\(model.sharedFolderName)",
                    detail: "在浏览器中直接管理共享与私人文件",
                    icon: "folder",
                    gradientColors: [],
                    badgeText: "直接打开"
                ) { model.openUserWeb(page: "files") }
                LiquidSanctuaryTile(
                    title: "时光相册",
                    subtitle: "缓存上限 \(thumbnailCacheMiB >= 1024 ? "\(thumbnailCacheMiB / 1024) GiB" : "\(thumbnailCacheMiB) MiB")",
                    detail: "浏览时间线、精选回忆与文件夹相册",
                    icon: "photo.on.rectangle",
                    gradientColors: [],
                    badgeText: "直接打开"
                ) { model.openUserWeb(page: "photos") }
                LiquidSanctuaryTile(
                    title: "私人影院",
                    subtitle: "海报墙与多端续播",
                    detail: "浏览电影与剧集，支持原画直放与字幕",
                    icon: "film",
                    gradientColors: [],
                    badgeText: "直接打开"
                ) { model.openUserWeb(page: "cinema") }
            }
            .disabled(model.state != .online)

            Text("空间配置与本地操作").font(.system(size: 15, weight: .semibold)).padding(.top, 4)
            IsleDestinationGrid {
                IsleDestinationRow(
                    title: "私人文件详情",
                    subtitle: "查看物理存储路径、在访达中打开共享目录",
                    icon: "folder.fill",
                    badge: model.sharedFolderPath == nil ? "待设置" : model.sharedFolderName,
                    badgeTone: model.sharedFolderPath == nil ? .warning : .success,
                    iconTint: IsleFluidPalette.brandCyan
                ) { requestNavigation(.files) }.modifier(IsleCascade(index: 0))
                IsleDestinationRow(
                    title: "时光相册设置",
                    subtitle: "查看相册原片存储说明与缩略图缓存策略",
                    icon: "photo.stack.fill",
                    badge: "原片留在本机",
                    badgeTone: .accent,
                    iconTint: IsleFluidPalette.brandViolet
                ) { requestNavigation(.photos) }.modifier(IsleCascade(index: 1))
                IsleDestinationRow(
                    title: "私人影院说明",
                    subtitle: "查看串流协议、FFmpeg 转码降级与字幕能力",
                    icon: "film.stack.fill",
                    badge: "直放优先",
                    badgeTone: .neutral,
                    iconTint: IsleFluidPalette.brandIndigo
                ) { requestNavigation(.cinema) }.modifier(IsleCascade(index: 2))
            }
            Text("日常浏览、上传与观影在独立的 Web 端或移动客户端中进行；Mac 管理端负责后台服务与存储。")
                .font(.system(size: 12.5)).foregroundStyle(IsleTheme.secondaryText).padding(.top, 4)
        }
    }
    var filesSpaceView: some View {
        VStack(alignment: .leading, spacing: 12) {
        spaceDetailCard(
            title: "私人文件",
            subtitle: "浏览已授权的共享目录，或在本机访达中打开当前存储位置。",
            icon: "folder.fill",
            gradient: [.cyan, .blue],
            badgeText: "本地共享",
            infoPairs: [
                ("共享目录名称", model.sharedFolderName),
                ("物理存储路径", model.sharedFolderPath ?? "未设置"),
                ("文件访问", "通过已授权的本地或局域网连接访问"),
                ("跨端支持", "Mac 访达 · Web / PWA · Flutter 客户端")
            ],
            primaryTitle: model.sharedFolderPath == nil ? "共享目录未设置 · 去选择存储位置" : "在访达中定位文件夹",
            primaryAction: {
                if let path = model.sharedFolderPath {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } else {
                    model.selectedSidebarPage = .storage
                }
            },
            secondaryTitle: "在 Web 空间查看文件 ↗",
            secondaryAction: { model.openUserWeb(page: "files") }
        )
        Button {
            model.selectedSidebarPage = .storage
        } label: {
            Label("设置文件存储位置 / 选择外接硬盘", systemImage: "externaldrive.badge.plus")
        }
        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .regular))
        }
    }

    var photosSpaceView: some View {
        spaceDetailCard(
            title: "时光相册",
            subtitle: "在独立 Web 空间浏览照片与视频；原始文件保存在配置的存储目录中。",
            icon: "photo.stack.fill",
            gradient: [Color(red: 0.95, green: 0.35, blue: 0.6), .purple],
            badgeText: "原片留在本机",
            infoPairs: [
                ("相册智能缓存", "\(thumbnailCacheMiB >= 1024 ? "\(thumbnailCacheMiB / 1024) GiB" : "\(thumbnailCacheMiB) MiB") 本地空间"),
                ("原片与原图", "存放于 Mac 本地共享目录，保留 Exif 完整元数据"),
                ("隐私等级", "本机解析；地图与媒体服务按已配置的外部服务工作"),
                ("浏览体验", "时间线浏览与按需加载原图")
            ],
            primaryTitle: "在 Web 空间打开时光相册 ↗",
            primaryAction: { model.openUserWeb(page: "photos") },
            secondaryTitle: "管理相册存储与缓存",
            secondaryAction: { model.selectedSidebarPage = .storage }
        )
    }

    var cinemaSpaceView: some View {
        spaceDetailCard(
            title: "私人影院",
            subtitle: "家庭多媒体娱乐中心，直放优先；安装 Homebrew FFmpeg 后可转封装与硬件转码。",
            icon: "film.stack.fill",
            gradient: [.orange, Color(red: 0.95, green: 0.3, blue: 0.2)],
            badgeText: "直放优先",
            infoPairs: [
                ("媒体串流协议", "HTTP 206 范围请求直放 · 浏览器可解码格式直接播放"),
                ("转码与降级", "未装 FFmpeg 时诚实降级为直放/下载，不虚标能力"),
                ("多语言字幕", "SRT / VTT 外挂字幕与内嵌字幕抽取（需 FFmpeg）"),
                ("观影断点记忆", "多终端自动同步播放进度")
            ],
            primaryTitle: "在 Web 空间开启私人影院 ↗",
            primaryAction: { model.openUserWeb(page: "cinema") },
            secondaryTitle: "管理影音媒体卷",
            secondaryAction: { model.selectedSidebarPage = .storage }
        )
    }

    func spaceDetailCard(title: String, subtitle: String, icon: String, gradient: [Color], badgeText: String,
                         infoPairs: [(String, String)], primaryTitle: String, primaryAction: @escaping () -> Void,
                         secondaryTitle: String, secondaryAction: @escaping () -> Void) -> some View {
        let tint = gradient.first ?? IsleTheme.accent
        return VStack(alignment: .leading, spacing: 22) {
            LiquidCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        IsleHeaderIconBadge(icon: icon, tint: tint, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(title).font(.system(size: 16, weight: .semibold))
                                IsleStatusPill(text: badgeText, tone: .accent)
                            }
                            Text(subtitle).font(.system(size: 13)).foregroundStyle(IsleTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { spaceActions(primaryTitle, primaryAction, secondaryTitle, secondaryAction) }
                        VStack(alignment: .leading, spacing: 10) { spaceActions(primaryTitle, primaryAction, secondaryTitle, secondaryAction) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            AppleSettingsGroup(title: "空间信息") {
                ForEach(Array(infoPairs.enumerated()), id: \.offset) { index, pair in
                    if index > 0 { IsleGroupSpacing(height: 4) }
                    AppleSettingsRow(title: pair.0) { Text(pair.1).font(.system(size: 13)).foregroundStyle(IsleTheme.secondaryText).textSelection(.enabled) }
                }
            }
        }
    }
    @ViewBuilder func spaceActions(_ primary: String, _ action: @escaping () -> Void, _ secondary: String, _ second: @escaping () -> Void) -> some View {
        Button(primary, action: action).buttonStyle(LiquidButtonStyle(variant: .prominent))
        Button(secondary, action: second).buttonStyle(LiquidButtonStyle())
    }
}
