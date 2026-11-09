import SwiftUI
import AppKit

struct DiskHealthDetails: View {
    let report: DiskHealthReport
    let fallbackSMART: String

    private var reasonText: String {
        switch report.reason {
        case "smartctl_not_installed":
            return "未安装 smartmontools，无法读取详细健康信息。可通过 Homebrew 安装（brew install smartmontools）后重试。"
        case "smartctl_permission_required":
            return "macOS 限制普通权限进程直读设备 SMART。可点击下方「使用管理员权限读取」授权一次（结果 5 分钟内对 Web 端同样可见），或按指引配置 sudoers 免密读取。"
        case "smartctl_device_unsupported":
            return "该磁盘的桥接芯片或控制器不支持通过 smartctl 读取 SMART；当前显示 macOS 基础状态。"
        default:
            return "SMART 查询失败，请稍后重试。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if report.source == "smartctl" {
                HealthDetailRow(title: "型号", value: report.model)
                HealthDetailRow(title: "序列号", value: report.serial)
                HealthDetailRow(title: "固件", value: report.firmware)
                HealthDetailRow(title: "温度", value: report.temperature.map { "\($0) °C" })
                HealthDetailRow(title: "SMART 结论", value: report.passed.map { $0 ? "健康（已通过）" : "警告：SMART 报告异常" },
                        highlight: report.passed == false ? .red : .teal)
                HealthDetailRow(title: "通电时长", value: report.powerOnHours.map { "\($0) 小时" })
                HealthDetailRow(title: "已用寿命", value: report.lifeUsed.map { "\($0)%" })
            } else {
                Label(reasonText, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.secondaryText)
            }
            Text("macOS 基础 SMART 状态：\(fallbackSMART.isEmpty ? "未知（设备可能不提供）" : fallbackSMART)")
                .font(.caption2)
                .foregroundStyle(IsleTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

private struct HealthDetailRow: View {
    let title: String
    let value: String?
    var highlight: Color?

    var body: some View {
        HStack(alignment: .top) {
            Text(title).font(.caption).foregroundStyle(IsleTheme.secondaryText)
            Spacer()
            Text(value ?? "—")
                .font(.caption.weight(.semibold))
                .foregroundStyle(highlight ?? Color.primary)
                .textSelection(.enabled)
        }
    }
}

/// Opt-in, fully manual sudoers rule so the Core can read SMART without any
/// password dialog. The rule is intentionally narrow: one binary at a
/// Homebrew path with fixed arguments. Nothing is written automatically.
struct SudoersGuideView: View {
    let device: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var binaryPath: String { SmartElevation.locateBinary() ?? "/opt/homebrew/bin/smartctl" }

    private var rule: String {
        let user = NSUserName()
        return "# 允许免密运行 smartctl 读取磁盘 SMART（只读）\n\(user) ALL=(root) NOPASSWD: \(binaryPath) --json -a /dev/disk[0-9]*"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("sudoers 免密读取 SMART").font(.system(size: 16, weight: .semibold))
            Text("以下步骤完全手动执行，轻屿不会替你修改 sudoers。配置后 SMART 详情不再弹密码框；删除该文件即可撤销。")
                .font(.caption).foregroundStyle(IsleTheme.secondaryText)
            LiquidCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. 在终端执行：").font(.system(size: 12, weight: .semibold))
                    Text("sudo visudo -f /etc/sudoers.d/lightisle-smart")
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Text("2. 写入以下内容并保存：").font(.system(size: 12, weight: .semibold))
                    Text(rule)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button(copied ? "已复制" : "复制规则") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(rule, forType: .string)
                            copied = true
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        Text("3. 校验语法：sudo visudo -c").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
            }
            Text("说明：规则只放行 smartctl 以固定参数读取 /dev/diskN；当前读取的是整盘（\(device)）。该白名单对终端同样生效，请仅在自己管理的 Mac 上配置。")
                .font(.caption).foregroundStyle(IsleTheme.secondaryText)
            Spacer()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
            }
        }
        .padding(20)
        .frame(width: 520, height: 380)
    }
}

/// The window frame and both navigation columns share one canvas. Content
/// keeps its normal safe area so scrolling never reaches the window controls.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) { view.scheduleApply() }

    final class ChromeView: NSView {
        private var updateScheduled = false
        #if DEBUG
        private weak var sizedPreviewWindow: NSWindow?
        #endif
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleApply() }
        func scheduleApply() {
            guard !updateScheduled else { return }
            updateScheduled = true
            // SwiftUI installs its toolbar during the same layout pass.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                self.apply()
            }
        }
        private func apply() {
            guard let window else { return }
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = NSColor(IsleFluidPalette.canvasTop)
            #if DEBUG
            // Window restoration can override SwiftUI's defaultSize. Isolated
            // visual fixtures need the requested outer size for honest QA.
            if AppModel.shared.isPresentationPreview, sizedPreviewWindow !== window {
                sizedPreviewWindow = window
                var frame = window.frame
                frame.origin.y += frame.height - NativeWindowSize.height
                frame.size = NSSize(width: NativeWindowSize.width, height: NativeWindowSize.height)
                window.setFrame(frame, display: true)
            }
            #endif
        }
    }
}
