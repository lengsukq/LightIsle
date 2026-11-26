import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

struct ConnectionQRCodePopoverButton: View {
    let urlString: String
    let label: String
    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            Image(systemName: "qrcode")
        }
        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
        .help("显示手机扫码连接二维码")
        .accessibilityLabel("显示\(label)二维码")
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                if let nsImage = Self.makeQRCode(from: urlString) {
                    Image(nsImage: nsImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 168, height: 168)
                        .padding(10)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Text(urlString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(IsleTheme.secondaryText)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                Text("手机浏览器或轻屿客户端扫码即可直连")
                    .font(.caption2)
                    .foregroundStyle(IsleTheme.secondaryText)
            }
            .padding(16)
            .frame(width: 236)
        }
    }

    private static func makeQRCode(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: transformed)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}

extension ContentView {
    private static let fallbackLocalMacName: String = {
        let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "本地 Mac" : name
    }()

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
                            HostMetricsObserver(store: model.hostMetrics) { telemetry in
                                let raw = telemetry.metrics?.hostname.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                Text(raw.isEmpty ? Self.fallbackLocalMacName : raw)
                                    .font(.system(size: 20, weight: .semibold))
                            }
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
                                IsleIconButton(
                                    icon: "doc.on.doc",
                                    help: "复制本机访问地址"
                                ) {
                                    PasteboardHelper.copy(endpoint)
                                    showNotice("已复制本机访问地址")
                                }
                            }
                        }
                        if let lan = model.remoteAddress {
                            HStack(spacing: 6) {
                                Text("局域网：" + lan)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(IsleTheme.secondaryText)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                                ConnectionQRCodePopoverButton(urlString: lan, label: "局域网扫码直连")
                            }
                        }
                    }
                }
            }
            attentionView
            RemovableMediaBannerView(coordinator: model.mediaImport, model: model)
            if !dismissedQuickReadyChecklist && model.state == .online {
                let storageReady = model.sharedFolderPath != nil
                let spaceReady = model.personalSpaces.users.count > 1 || hasCompletedPersonalSpaceStep
                let lanReady = model.remoteAddress != nil
                if !(storageReady && spaceReady && lanReady) {
                    LiquidCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("新手 3 步快速上手向导", systemImage: "sparkles")
                                    .font(.system(size: 13.5, weight: .semibold))
                                Spacer()
                                if !spaceReady {
                                    Button("仅本人使用·完成第 3 步") {
                                        withAnimation(reduceMotion ? nil : IsleMotion.standard) {
                                            hasCompletedPersonalSpaceStep = true
                                        }
                                    }
                                    .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                                }
                                Button("收起引导") {
                                    withAnimation(reduceMotion ? nil : IsleMotion.standard) {
                                        dismissedQuickReadyChecklist = true
                                    }
                                }
                                .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                            }
                            HStack(spacing: 10) {
                                quickReadyStepPill(
                                    done: storageReady,
                                    title: "1. 确认存储硬盘",
                                    actionLabel: storageReady ? "已就绪" : "去选择"
                                ) { requestNavigation(.storage); storageDetail = .locations }
                                quickReadyStepPill(
                                    done: lanReady,
                                    title: "2. 开启局域网直连",
                                    actionLabel: lanReady ? "已开启" : "去开启"
                                ) { requestNavigation(.services); connectionDetail = .lan }
                                quickReadyStepPill(
                                    done: spaceReady,
                                    title: "3. 进入 Web 空间或添加家人",
                                    actionLabel: spaceReady ? "已完成" : "打开空间"
                                ) {
                                    hasCompletedPersonalSpaceStep = true
                                    model.openUserWeb()
                                }
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
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
                LiquidSanctuaryTile(title: "私人文件", subtitle: "文件与共享目录", detail: "在 Web 空间打开", icon: "folder", badgeText: nil) { model.openUserWeb(page: "files") }
                LiquidSanctuaryTile(title: "时光相册", subtitle: "照片与视频回忆", detail: "在 Web 空间打开", icon: "photo.on.rectangle", badgeText: nil) { model.openUserWeb(page: "photos") }
                LiquidSanctuaryTile(title: "私人影院", subtitle: "影片与剧集", detail: "在 Web 空间打开", icon: "film", badgeText: nil) { model.openUserWeb(page: "cinema") }
            }.disabled(model.state != .online)
        }
    }
    @ViewBuilder var attentionView: some View {
        if model.state != .online {
            attentionRow("核心服务尚未就绪", message: model.details, action: "重新启动") { model.launch() }
        }
        if model.state == .online {
            ForEach(model.coreServiceWarnings, id: \.self) { warning in
                Text(warning).font(.caption).foregroundStyle(IsleTheme.warningText)
            }
            if model.coreCommandWarning {
                Text("有管理请求因通道繁忙未提交。请刷新对应页面后重试。")
                    .font(.caption).foregroundStyle(IsleTheme.warningText)
            }
            if let incident = model.coreLastIncident {
                Text("最近服务中断：\(incident)").font(.caption).foregroundStyle(IsleTheme.secondaryText)
            }
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
        HostMetricsObserver(store: model.hostMetrics) { telemetry in
            let m = telemetry.metrics
            let memTotal = m?.memoryTotal ?? 0
            let memUsed = min(m?.memoryUsed ?? 0, memTotal)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Mac 运行状态").font(.system(size: 15, weight: .semibold))
                    if let pwr = telemetry.powerSnapshot, pwr.available, (pwr.upsPresent || pwr.onBattery) {
                        IsleStatusPill(
                            text: pwr.statusLabel,
                            tone: pwr.onBattery ? .warning : .success,
                            icon: pwr.onBattery ? "bolt.batteryblock.fill" : "powerplug"
                        )
                        .help(pwr.detailLabel)
                    }
                    Spacer()
                    Text(telemetry.lastMetricsAt.map { "采样于 " + IsleFormatters.timeHMS($0) } ?? "读取中…")
                        .font(.system(size: 12)).foregroundStyle(IsleTheme.secondaryText)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 14)], spacing: 14) {
                    let appRss = LightIsleHostMemory.residentBytes() ?? 0
                    let coreRss = m?.coreRssBytes ?? 0
                    let memSlices = memTotal > 0 ? IsleStorageChartBuilder.memorySlices(
                        total: memTotal,
                        used: memUsed,
                        appRss: appRss,
                        coreRss: coreRss
                    ) : nil
                    LiquidHealthGauge(
                        title: "处理器",
                        valueText: m?.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "读取中…",
                        subtext: m.map { "\($0.cpuCount) 个核心" } ?? "尚无读数",
                        progress: m?.cpuPercent.map { $0 / 100 },
                        tint: IsleTheme.accent,
                        icon: "cpu",
                        sparklineValues: telemetry.metricHistory.map(\.cpu),
                        sparklineMax: 100
                    )
                    LiquidHealthGauge(
                        title: "内存",
                        valueText: memTotal > 0 ? formatBytes(memUsed) : "读取中…",
                        subtext: memTotal > 0 ? "总计 \(formatBytes(memTotal))" : "尚无读数",
                        progress: memTotal > 0 ? Double(memUsed) / Double(memTotal) : nil,
                        tint: IsleFluidPalette.brandViolet,
                        icon: "memorychip",
                        sparklineValues: telemetry.metricHistory.map(\.memory),
                        sparklineMax: 100,
                        segmentedSlices: memSlices,
                        segmentedTotal: memTotal > 0 ? Double(memTotal) : nil
                    )
                    LiquidHealthGauge(
                        title: "网络下载",
                        valueText: m?.networkDownBps.map { formatRate($0) + "/s" } ?? "读取中…",
                        subtext: "本机所有网络接口合计",
                        progress: nil,
                        tint: IsleFluidPalette.brandCyan,
                        icon: "arrow.down",
                        sparklineValues: telemetry.metricHistory.map(\.download)
                    )
                    LiquidHealthGauge(
                        title: "网络上传",
                        valueText: m?.networkUpBps.map { formatRate($0) + "/s" } ?? "读取中…",
                        subtext: "本机所有网络接口合计",
                        progress: nil,
                        tint: IsleFluidPalette.brandIndigo,
                        icon: "arrow.up",
                        sparklineValues: telemetry.metricHistory.map(\.upload)
                    )
                }
                if let volumeSnapshot = overviewVolumeChartSnapshot(from: m) {
                    overviewVolumeDistributionCard(volumeSnapshot)
                }
            }
            .onAppear { model.refreshPowerSnapshotIfNeeded() }
        }
    }

    private func overviewVolumeChartSnapshot(from metrics: HostMetrics?) -> (title: String, subtitle: String, total: UInt64, free: UInt64, rootID: String?, generation: UInt64?)? {
        let defaultRoot = model.rootManagement.defaultRoot
        let defaultPath = defaultRoot?.path ?? model.sharedFolderPath
        if let volumes = metrics?.volumes,
           let mount = StorageVolumeSelection.matchingMount(for: defaultPath, mounts: volumes.map(\.mount)),
           let vol = volumes.first(where: { $0.mount == mount }),
           vol.total > 0 {
            return (
                title: "主存储空间构成 · \(vol.mount == "/" ? "Mac 系统盘" : vol.name)",
                subtitle: "\(vol.filesystem) · 可用 \(formatBytes(vol.free)) / 共 \(formatBytes(vol.total))",
                total: vol.total,
                free: vol.free,
                rootID: defaultRoot?.rootID,
                generation: defaultRoot?.generation
            )
        }
        if let m = metrics, m.diskTotal > 0 {
            return (
                title: "宿主 Mac 磁盘空间构成",
                subtitle: "可用 \(formatBytes(m.diskFree)) / 共 \(formatBytes(m.diskTotal))",
                total: m.diskTotal,
                free: m.diskFree,
                rootID: nil,
                generation: nil
            )
        }
        return nil
    }

    private func overviewVolumeDistributionCard(_ snap: (title: String, subtitle: String, total: UInt64, free: UInt64, rootID: String?, generation: UInt64?)) -> some View {
        let clampedFree = min(snap.free, snap.total)
        let usedRatio = Double(snap.total - clampedFree) / Double(max(snap.total, 1))
        let slices = IsleStorageChartBuilder.volumeSlices(
            total: snap.total,
            free: clampedFree,
            rootID: snap.rootID,
            rootGeneration: snap.generation,
            users: model.personalSpaces.users
        )
        return HStack(alignment: .center, spacing: 16) {
            IsleDonutGauge(
                progress: usedRatio,
                centerText: "\(Int(round(usedRatio * 100)))%",
                centerSubtext: "已用",
                tint: usedRatio > 0.88 ? .orange : IsleFluidPalette.brandCyan,
                size: 62,
                lineWidth: 6.5,
                accessibilityLabel: snap.title
            )
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(snap.title)
                        .font(.system(size: 13.5, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(snap.subtitle)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(IsleTheme.secondaryText)
                }
                IsleSegmentedBar(
                    slices: slices,
                    total: Double(snap.total),
                    barHeight: 10,
                    showsLegend: true,
                    legendMinimumWidth: 140,
                    accessibilityTitle: snap.title
                )
            }
        }
        .padding(16)
        .modifier(IsleEmbossedSurface())
    }
    var diagnosticsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            BetaDiagnosticControls(model: model)
            HostMetricsObserver(store: model.hostMetrics) { telemetry in
                VStack(alignment: .leading, spacing: 20) {
                    AppleSettingsGroup(title: "应用资源占用", footer: "当前常驻内存；不同于整个 Mac 的内存用量。") {
                        AppleSettingsRow(title: "Mac 管理界面") { Text(LightIsleHostMemory.residentBytes().map(formatBytes) ?? "暂无数据").monospacedDigit() }
                        IsleGroupSpacing(height: 4)
                        AppleSettingsRow(title: "Core 服务") { Text(telemetry.metrics?.coreRssBytes.map(formatBytes) ?? "暂无数据").monospacedDigit() }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                        IsleHistoryGraph(title: "处理器 (%)", values: telemetry.metricHistory.map(\.cpu), maximum: 100, tint: IsleTheme.accent)
                        IsleHistoryGraph(title: "内存 (%)", values: telemetry.metricHistory.map(\.memory), maximum: 100, tint: IsleTheme.accent)
                        IsleHistoryGraph(title: "下载速率", values: telemetry.metricHistory.map(\.download), maximum: max(telemetry.metricHistory.map(\.download).max() ?? 1, 1), tint: IsleTheme.accent)
                        IsleHistoryGraph(title: "上传速率", values: telemetry.metricHistory.map(\.upload), maximum: max(telemetry.metricHistory.map(\.upload).max() ?? 1, 1), tint: IsleTheme.accent)
                    }
                    processMonitorView(metrics: telemetry.metrics)
                }
            }
        }.onAppear { model.setDiagnosticsVisible(true) }.onDisappear { model.setDiagnosticsVisible(false) }
    }

    func quickReadyStepPill(done: Bool, title: String, actionLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? IsleTheme.successText : IsleTheme.accent)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(actionLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(done ? IsleTheme.secondaryText : IsleTheme.accent)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(done ? IsleTheme.successText.opacity(0.08) : Color.primary.opacity(0.035))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(done ? IsleTheme.successText.opacity(0.24) : IsleFluidPalette.rim.opacity(0.55), lineWidth: 0.9)
            }
        }
        .buttonStyle(IslePressStyle())
    }
}
