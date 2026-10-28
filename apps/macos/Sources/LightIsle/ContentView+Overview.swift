import SwiftUI

extension ContentView {
    var overviewView: some View {
        VStack(alignment: .leading, spacing: 24) {
            LiquidCard {
                HStack(alignment: .center, spacing: 18) {
                    Image(systemName: model.state == .online ? "desktopcomputer" : "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .regular)).foregroundStyle(IsleFluidPalette.brandBlue)
                        .frame(width: 60, height: 60).background(IsleFluidPalette.brandBlue.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.metrics?.hostname ?? "本地 Mac").font(.system(size: 20, weight: .semibold))
                        Text(model.state == .online ? "轻屿正在这台 Mac 上提供服务" : model.details)
                            .font(.system(size: 13)).foregroundStyle(IsleTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 10)
                    StatusBadge(isOnline: model.state == .online, text: model.state.label)
                }
            }
            attentionView
            VStack(alignment: .leading, spacing: 12) {
                Text("存储与连接").font(.system(size: 15, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 285), spacing: 14)], spacing: 14) {
                    summaryCard(title: "存储位置", value: model.sharedFolderPath == nil ? "尚未就绪" : model.sharedFolderName,
                                subtitle: model.sharedFolderPath ?? model.offlineSharedFolderPath ?? "选择专用文件夹以开始使用",
                                icon: "externaldrive", rows: storagePreviewRows) { requestNavigation(.storage) }
                    summaryCard(title: "设备连接", value: model.remoteAddress == nil ? "仅本机访问" : "局域网已启用",
                                subtitle: model.remoteAddress ?? model.endpoint?.absoluteString ?? "等待核心服务",
                                icon: "network", rows: [("本机地址", model.endpoint?.absoluteString ?? "未取得"), ("局域网", model.remoteAddress ?? "未启用")]) { requestNavigation(.services) }
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
    func summaryCard(title: String, value: String, subtitle: String, icon: String, rows: [(String, String)], action: @escaping () -> Void) -> some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(title, systemImage: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(icon == "externaldrive" ? IsleFluidPalette.brandCyan : IsleFluidPalette.brandBlue)
                    Spacer()
                    IsleDetailInfo(title: title, rows: rows)
                }
                Button(action: action) {
                    HStack { Text(value).font(.system(size: 17, weight: .semibold)); Spacer(); Image(systemName: "arrow.right").font(.system(size: 13)) }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help("查看" + title + "的设置与详情")
                Text(subtitle).font(.system(size: 13)).foregroundStyle(IsleTheme.secondaryText).lineLimit(2).truncationMode(.middle)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
