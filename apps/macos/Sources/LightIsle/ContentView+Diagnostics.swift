import SwiftUI
import AppKit

extension ContentView {
    var processMonitorView: some View {
        let processes = (model.metrics?.processes ?? []).sorted { first, second in
            let firstValue = processSortByMemory ? first.rssBytes.map(Double.init) : first.cpuPercent
            let secondValue = processSortByMemory ? second.rssBytes.map(Double.init) : second.cpuPercent
            switch (firstValue, secondValue) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return first.pid < second.pid
            }
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("活动进程列表")
                        .font(.system(size: 13, weight: .semibold))
                    Text("只读采样 · 详情受 macOS 系统安全权限控制")
                        .font(.system(size: 11))
                        .foregroundStyle(IsleTheme.secondaryText)
                }
                Spacer()
                LiquidSegmentedPicker(
                    title: "进程排序方式",
                    selection: $processSortByMemory,
                    options: [
                        LiquidMenuOption(value: false, label: "按 CPU"),
                        LiquidMenuOption(value: true, label: "按内存")
                    ]
                )
                Button {
                    model.openActivityMonitor()
                } label: {
                    Label("活动监视器", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
            }

            HStack(spacing: 12) {
                Text("进程名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU").frame(width: 70, alignment: .trailing)
                Text("物理内存").frame(width: 85, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(IsleTheme.secondaryText)
            .padding(.horizontal, 4)

            if processes.isEmpty {
                Text("暂无进程信息").font(.caption).foregroundStyle(IsleTheme.secondaryText)
            } else {
                ForEach(Array(processes.prefix(10))) { process in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(process.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text("PID \(process.pid)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(IsleTheme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "–")
                            .frame(width: 70, alignment: .trailing)
                            .font(.system(size: 11, design: .monospaced))

                        Text(process.rssBytes.map(formatBytes) ?? "–")
                            .frame(width: 85, alignment: .trailing)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(IsleTheme.secondaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                }
            }
        }
    }

    func formatBytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    func formatRate(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    /// volume.device is a partition BSD name ("disk4s1"); counters are keyed
    /// by the whole disk ("disk4").
    func diskActivity(for device: String) -> String? {
        guard let io = model.metrics?.diskIo, !io.isEmpty else { return nil }
        let whole = device.split(separator: "s").first.map(String.init) ?? device
        guard let entry = io.first(where: { $0.device == whole }),
              let read = entry.readBps, let write = entry.writeBps,
              read >= 1 || write >= 1 else { return nil }
        return "读 \(formatRate(read))/s · 写 \(formatRate(write))/s"
    }

    var thresholdSummary: String {
        guard let threshold = model.storageThreshold else { return "读取中…" }
        let gib = Double(threshold.freeMiB) / 1024.0
        let gibText = gib == gib.rounded() ? String(Int(gib)) : String(format: "%.1f", gib)
        return "剩余低于 \(gibText) GiB 或总容量 \(threshold.percent)%"
    }

    func syncThresholdDraft() {
        guard let threshold = model.storageThreshold else { return }
        if thresholdFreeMiBText.isEmpty {
            let gib = Double(threshold.freeMiB) / 1024.0
            thresholdFreeMiBText = gib == gib.rounded() ? String(Int(gib)) : String(format: "%.1f", gib)
        }
        if thresholdPercentText.isEmpty {
            thresholdPercentText = String(threshold.percent)
        }
    }

    func applyThresholdDraft() {
        guard let (miB, percentage) = NativeFormValidation.threshold(gib: thresholdFreeMiBText, percent: thresholdPercentText,
                priorMiB: model.storageThreshold?.freeMiB ?? 2048, priorPercent: model.storageThreshold?.percent ?? 5) else {
            draftError = "请输入有效阈值：剩余空间 0–1024 GiB、百分比为 0–50 的整数，两项不能同时为 0。"
            pendingDraftSaves.remove(.threshold); saveBeforeLeaving = false
            return
        }
        guard model.state == .online else { draftError = "核心服务未就绪，阈值尚未保存。"; pendingDraftSaves.remove(.threshold); saveBeforeLeaving = false; return }
        draftError = nil
        model.applyStorageThreshold(StorageThreshold(freeMiB: miB, percent: percentage))
    }

    var tunnelBinaryDescription: String {
        if let path = model.tunnelState?.binary, !path.isEmpty {
            return "已找到：\(path)"
        }
        return "未找到 cloudflared。请先安装：brew install cloudflared"
    }

    var tunnelStatusDescription: String {
        guard let state = model.tunnelState else { return "等待 Core 就绪…" }
        var text = state.statusDescription
        if state.mode == "quick" {
            text += " · 免费模式"
        } else if state.mode == "named" {
            text += " · 命名隧道\(state.tunnelName.map { "「\($0)」" } ?? "")"
        }
        return text
    }

    var tunnelStatusColor: Color {
        switch model.tunnelState?.status {
        case "online": return .green
        case "starting": return .orange
        case "error": return .red
        default: return .secondary
        }
    }

    func tunnelErrorDescription(_ code: String) -> String {
        switch code {
        case "cloudflared_not_found":
            return "未找到 cloudflared 二进制。请先执行 brew install cloudflared，然后重启轻屿。"
        case "tunnel_already_running":
            return "已有一个隧道在运行；请先停止再切换模式。"
        case "tunnel_not_running":
            return "目前没有运行中的隧道，无需停止。请刷新后确认状态。"
        case "tunnel_token_required":
            return "尚未配置 Cloudflare API Token，请先填写并验证令牌后重试。"
        case "tunnel_config_invalid", "invalid_tunnel_request":
            return "隧道配置内容无效，请核对域名、Token 和模式后重试。"
        case "tunnel_start_failed":
            return "无法启动 Cloudflare Tunnel，请检查网络、授权和 cloudflared 安装状态。"
        default:
            return "隧道操作未完成，请刷新状态后重试。如持续失败请向管理员提供排查标识：\(code)"
        }
    }

    func frpErrorDescription(_ code: String) -> String {
        switch code {
        case "frpc_not_installed": return "尚未下载客户端，请先获取并选择 FRP 版本。"
        case "frpc_config_incomplete": return "配置文件中仍有服务端占位值，请打开 frpc.toml 完成配置后再启动。"
        case "frp_busy": return "FRP 正在运行或安装中，请先停止，或等当前下载完成。"
        case "frpc_checksum_mismatch": return "下载校验失败，已拒绝安装。请检查网络或代理后重试。"
        case "frpc_version_unavailable": return "该版本不可安装。请刷新列表并选择提供 macOS ARM64 文件及 SHA-256 校验的版本。"
        case "frpc_github_rate_limited": return "GitHub API 请求过于频繁，稍后点击「获取版本」重试。"
        case "frpc_versions_empty": return "官方没有返回可识别的 FRP 版本。"
        case "frpc_unsupported_platform": return "当前设备不支持这个 FRP 安装包，需要 Apple Silicon macOS 版本。"
        case "frpc_download_too_large", "frpc_invalid_archive", "frpc_binary_missing_in_archive": return "FRP 下载文件不符合安全校验，已拒绝安装。请刷新版本列表后重试。"
        case "frpc_untrusted_download_redirect": return "FRP 下载被重定向到非官方来源，已拒绝下载。请检查网络代理。"
        case "frpc_config_directory_unavailable": return "无法访问 FRP 配置目录，请检查 Mac 的磁盘权限后重试。"
        case "frpc_unsafe_path": return "FRP 文件路径不是普通文件，为安全起见已拒绝使用。请检查文件位置。"
        case "frpc_exited", "frpc_exited_unexpectedly": return "frpc 进程已退出。请检查 frpc.toml 的服务端地址、令牌、代理规则及远端 frps 状态。"
        default: return "FRP 操作未完成，请检查配置及网络后重试。如持续失败请向管理员提供排查标识：\(code)"
        }
    }}
