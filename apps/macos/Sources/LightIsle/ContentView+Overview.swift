import SwiftUI

extension ContentView {
    var overviewView: some View {
        VStack(alignment: .leading, spacing: 24) {
            LiquidCard {
                HStack(alignment: .center, spacing: 18) {
                    IsleHeaderIconBadge(
                        icon: model.state == .online ? "desktopcomputer" : "exclamationmark.triangle",
                        tint: IsleFluidPalette.brandBlue,
                        size: 56
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(model.metrics?.hostname ?? "本地 Mac").font(.system(size: 20, weight: .semibold))
                            IsleStatusPill(
                                text: model.state.label,
                                tone: model.state == .online ? .success : .warning,
                                showDot: true
                            )
                            if model.isRemoteEnabled {
                                IsleStatusPill(text: "局域网已开启", tone: .accent, icon: "wifi")
                            }
                        }
                        Text(model.state == .online ? "轻屿正在这台 Mac 上提供服务，所有个人数据保存在你指定的本机或外置磁盘。" : model.details)
                            .font(.system(size: 13)).foregroundStyle(IsleTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 10)
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(model.endpoint?.absoluteString ?? "等待本机 Web 服务就绪")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            if let endpoint = model.endpoint?.absoluteString {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(endpoint, forType: .string)
                                    showNotice("已复制本机访问地址")
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                .help("复制本机访问地址")
                            }
                        }
                        if let lan = model.remoteAddress {
                            Text("局域网：" + lan)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(IsleTheme.secondaryText)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            attentionView
            VStack(alignment: .leading, spacing: 12) {
                Text("存储与连接").font(.system(size: 15, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14)], spacing: 14) {
                    summaryCard(
                        title: "存储位置",
                        value: model.sharedFolderPath == nil ? "尚未就绪" : model.sharedFolderName,
                        subtitle: model.sharedFolderPath ?? model.offlineSharedFolderPath ?? "选择专用文件夹以开始使用",
                        icon: "externaldrive",
                        tint: IsleFluidPalette.brandCyan,
                        badge: model.sharedFolderPath != nil ? "在线" : "待处理",
                        badgeTone: model.sharedFolderPath != nil ? .success : .warning,
                        rows: storagePreviewRows
                    ) { requestNavigation(.storage) }
                    summaryCard(
                        title: "设备连接",
                        value: model.remoteAddress == nil ? "仅本机访问" : "局域网已启用",
                        subtitle: model.remoteAddress ?? model.endpoint?.absoluteString ?? "等待核心服务",
                        icon: "network",
                        tint: IsleFluidPalette.brandBlue,
                        badge: model.remoteAddress != nil ? (model.remoteAddress?.hasPrefix("https://") == true ? "HTTPS" : "HTTP") : "本机回环",
                        badgeTone: model.remoteAddress != nil ? .success : .neutral,
                        rows: [("本机地址", model.endpoint?.absoluteString ?? "未取得"), ("局域网", model.remoteAddress ?? "未启用")]
                    ) { requestNavigation(.services) }
                }
            }
            overviewMetrics
            HStack {
                Text("个人空间").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("查看全部") { requestNavigation(.spaces) }.buttonStyle(LiquidButtonStyle(variant: .borderless))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                LiquidSanctuaryTile(title: "私人文件", subtitle: "文件与共享目录", detail: "在 Web 空间打开", icon: "folder", gradientColors: [], badgeText: nil) { model.openUserWeb(page: "files") }
                LiquidSanctuaryTile(title: "时光相册", subtitle: "照片与视频回忆", detail: "在 Web 空间打开", icon: "photo.on.rectangle", gradientColors: [], badgeText: nil) { model.openUserWeb(page: "photos") }
                LiquidSanctuaryTile(title: "私人影院", subtitle: "影片与剧集", detail: "在 Web 空间打开", icon: "film", gradientColors: [], badgeText: nil) { model.openUserWeb(page: "cinema") }
            }.disabled(model.state != .online)
        }
    }
    @ViewBuilder var attentionView: some View {
        if model.state != .online {
            attentionRow("核心服务尚未就绪", message: model.details, action: "重新启动") { model.launch() }
        }
        if model.sharedFolderPath == nil {
            attentionRow(model.offlineSharedFolderPath == nil ? "尚未设置存储位置" : "共享存储已离线", message: model.activeAlerts.first(where: { $0.code == "storage_offline" })?.message ?? "连接原磁盘或检查存储登记，原有文件不会自动删除。", action: "查看存储") {
                requestNavigation(.storage); storageDetail = .locations
            }
        }
        ForEach(Array(model.activeAlerts.filter { !($0.code == "storage_offline" && model.sharedFolderPath == nil) }.enumerated()), id: \.offset) { _, alert in
            attentionRow(alert.severity == "critical" ? "需要处理" : "运行提醒", message: alert.message, action: "查看详情") {
                if alert.code.contains("backup") { requestNavigation(.storage); storageDetail = .backup }
                else if alert.code.contains("storage") { requestNavigation(.storage); storageDetail = .locations }
                else { requestNavigation(.settings); settingsDetail = .tools }
            }
        }
    }
    func attentionRow(_ title: String, message: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(IsleTheme.warningText).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(message).font(.system(size: 13)).foregroundStyle(IsleTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action, action: perform).buttonStyle(LiquidButtonStyle())
        }.padding(16).modifier(IsleEmbossedSurface())
    }
    func summaryCard(
        title: String,
        value: String,
        subtitle: String,
        icon: String,
        tint: Color,
        badge: String,
        badgeTone: IsleStatusTone,
        rows: [(String, String)],
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(IsleTheme.secondaryText)
                    IsleStatusPill(text: badge, tone: badgeTone, showDot: badgeTone == .success || badgeTone == .warning)
                    Spacer(minLength: 32)
                }
                HStack {
                    Text(value).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 24, height: 24)
                        .background(tint.opacity(0.09), in: Circle())
                }
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(IsleTheme.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(IsleItemCardSurface(interactive: true))
            .contentShape(Rectangle())
        }
        .buttonStyle(IslePressStyle())
        .help("查看" + title + "的设置与详情")
        .overlay(alignment: .topTrailing) {
            IsleDetailInfo(title: title, rows: rows)
                .padding(.top, 14)
                .padding(.trailing, 14)
        }
    }
    var overviewMetrics: some View {
        let m = model.metrics
        let memTotal = m?.memoryTotal ?? 0
        let memUsed = min(m?.memoryUsed ?? 0, memTotal)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mac 运行状态").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(model.lastMetricsAt.map { "采样于 " + $0.formatted(date: .omitted, time: .standard) } ?? "等待采样")
                    .font(.system(size: 12)).foregroundStyle(IsleTheme.secondaryText)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                LiquidHealthGauge(title: "处理器", valueText: m?.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "等待采样",
                                  subtext: m.map { "\($0.cpuCount) 个核心" } ?? "尚无读数", progress: m?.cpuPercent.map { $0 / 100 }, tint: IsleTheme.accent, icon: "cpu")
                LiquidHealthGauge(title: "内存", valueText: memTotal > 0 ? formatBytes(memUsed) : "等待采样",
                                  subtext: memTotal > 0 ? "总计 \(formatBytes(memTotal))" : "尚无读数", progress: memTotal > 0 ? Double(memUsed) / Double(memTotal) : nil, tint: IsleFluidPalette.brandViolet, icon: "memorychip")
                LiquidHealthGauge(title: "网络下载", valueText: m?.networkDownBps.map { formatRate($0) + "/s" } ?? "等待采样",
                                  subtext: "本机所有网络接口合计", progress: nil, tint: IsleFluidPalette.brandCyan, icon: "arrow.down")
                LiquidHealthGauge(title: "网络上传", valueText: m?.networkUpBps.map { formatRate($0) + "/s" } ?? "等待采样",
                                  subtext: "本机所有网络接口合计", progress: nil, tint: IsleFluidPalette.brandIndigo, icon: "arrow.up")
            }
        }
    }
    var diagnosticsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(title: "应用资源占用", footer: "当前常驻内存；不同于整个 Mac 的内存用量。") {
                AppleSettingsRow(title: "Mac 管理界面") { Text(LightIsleHostMemory.residentBytes().map(formatBytes) ?? "暂无数据").monospacedDigit() }
                IsleGroupSpacing(height: 4)
                AppleSettingsRow(title: "Core 服务") { Text(model.metrics?.coreRssBytes.map(formatBytes) ?? "暂无数据").monospacedDigit() }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                IsleHistoryGraph(title: "处理器 (%)", values: model.metricHistory.map(\.cpu), maximum: 100, tint: IsleTheme.accent)
                IsleHistoryGraph(title: "内存 (%)", values: model.metricHistory.map(\.memory), maximum: 100, tint: IsleTheme.accent)
                IsleHistoryGraph(title: "下载速率", values: model.metricHistory.map(\.download), maximum: max(model.metricHistory.map(\.download).max() ?? 1, 1), tint: IsleTheme.accent)
                IsleHistoryGraph(title: "上传速率", values: model.metricHistory.map(\.upload), maximum: max(model.metricHistory.map(\.upload).max() ?? 1, 1), tint: IsleTheme.accent)
            }
            processMonitorView
        }.onAppear { model.setDiagnosticsVisible(true) }.onDisappear { model.setDiagnosticsVisible(false) }
    }
}
