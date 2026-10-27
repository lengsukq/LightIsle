import AppKit
import SwiftUI

/// All package changes stay behind an explicit local Mac action. There is
/// deliberately no HTTP endpoint, automation-script hook or auto-install.
struct ExternalDependenciesView: View {
    @ObservedObject var store: ExternalDependencyStore
    let navigate: (SidebarPage) -> Void
    @State private var showInstallLog = false
    @State private var copiedGuideCommand: String?

    private var isBusy: Bool { store.installing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            IsleSectionHeader(
                title: "按需安装，不随应用捆绑",
                subtitle: "LightIsle 使用 Mac 已安装的命令行工具。这里只检测状态；点击「安装」并确认后才调用本机 Homebrew，不会自动安装、升级或卸载组件。"
            )

            AppleSettingsGroup(title: "安装环境") {
                AppleSettingsRow(
                    title: "Homebrew",
                    subtitle: store.brewPath ??
                        "未在标准位置检测到 Homebrew。可使用下方安装向导，安装后返回刷新。",
                    icon: "shippingbox.fill", iconTint: .blue
                ) {
                    HStack(spacing: 8) {
                        Text(store.brewPath == nil ? "未检测到" : "可用")
                            .font(.caption)
                            .foregroundStyle(store.brewPath == nil ? .orange : .green)
                        if store.brewPath == nil {
                            Button("查看官网") { openOfficialURL("https://brew.sh/zh-cn/") }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                        Button {
                            store.refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("重新检测外部依赖")
                        .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                        .disabled(isBusy)
                    }
                }
            }

            if store.brewPath == nil {
                homebrewSetupGuide
            }

            AppleSettingsGroup(
                title: "可一键安装的组件",
                footer: "安装命令使用固定包名和绝对路径执行，不通过 Shell；Homebrew 会从其软件源下载第三方组件。安装结果以本机实际检测到的可执行文件为准。"
            ) {
                ForEach(ExternalDependency.allCases) { dependency in
                    AppleSettingsRow(
                        title: dependency.title,
                        subtitle: dependency.purpose,
                        icon: dependency.symbol, iconTint: .indigo
                    ) {
                        HStack(spacing: 8) {
                            if let path = store.installed[dependency] {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("已检测到")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .help(path)
                            } else if store.installing == dependency {
                                ProgressView().controlSize(.small)
                                Text("安装中…")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("未安装")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("安装") {
                                    confirmInstall(dependency)
                                }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                .disabled(isBusy || store.brewPath == nil)
                            }
                        }
                    }
                    if dependency != ExternalDependency.allCases.last {
                        Divider().padding(.leading, 44)
                    }
                }
            }

            if let message = store.message {
                Label(message, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !store.lastLog.isEmpty {
                DisclosureGroup("查看最近一次安装日志", isExpanded: $showInstallLog) {
                    ScrollView {
                        Text(store.lastLog)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    .padding(10)
                    .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
                .font(.caption)
            }

            AppleSettingsGroup(
                title: "独立管理的组件",
                footer: "FRP 由现有的版本选择和官方摘要校验流程管理；Docker Desktop / Colima 涉及虚拟机及授权，不提供静默安装。"
            ) {
                AppleSettingsRow(
                    title: "FRP 客户端",
                    subtitle: "选择官方版本，校验 SHA-256 后按需安装。这里不重复下载或替换已运行的 frpc。",
                    icon: "network", iconTint: .teal
                ) {
                    Button("打开 FRP 设置") { navigate(.services) }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
                Divider().padding(.leading, 44)
                AppleSettingsRow(
                    title: "Docker Desktop / Colima",
                    subtitle: "只连接与管理用户已有的容器引擎，不在 LightIsle 中安装运行时。",
                    icon: "shippingbox", iconTint: .indigo
                ) {
                    Button("打开 Docker 管理") { navigate(.containers) }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
            }

            Text("提示：安装成功不代表自动启用功能。请在对应页面刷新，必要时重新启动 LightIsle 以便 Core 识别新依赖；smartctl 可能仍需要设备权限。安装过程中可以切换页面，但应避免退出 App。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { store.refresh() }
    }

    private var homebrewSetupGuide: some View {
        AppleSettingsGroup(
            title: "Homebrew 安装引导",
            footer: "Homebrew 安装属于系统软件管理，可能需要管理员密码、网络访问或安装 Xcode Command Line Tools。LightIsle 只提供官方渠道与可复制命令，不会代替你运行远程脚本。"
        ) {
            VStack(alignment: .leading, spacing: 13) {
                Label(
                    "首次使用只需要安装一次 Homebrew，之后就能在这里一键安装 FFmpeg、aria2 等依赖。",
                    systemImage: "info.circle"
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("方式一 · 图形化安装（推荐）")
                        .font(.system(size: 13, weight: .semibold))
                    Text("从 Homebrew 官方 GitHub 发布页下载适合 Apple Silicon 的 .pkg 安装程序，按系统提示完成安装。无需复制终端脚本。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("打开官方安装包下载页") {
                        openOfficialURL("https://github.com/Homebrew/brew/releases/latest")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }

                Divider()

                VStack(alignment: .leading, spacing: 7) {
                    Text("方式二 · 官方终端命令")
                        .font(.system(size: 13, weight: .semibold))
                    Text("复制以下官网命令，在 macOS「终端」中粘贴运行；安装脚本会先说明要执行的操作，并请求确认。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ExternalDependencyInstaller.officialBrewInstallCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                    HStack(spacing: 8) {
                        Button("复制安装命令") {
                            copyGuideCommand(ExternalDependencyInstaller.officialBrewInstallCommand)
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        Button("打开终端") {
                            if let terminal = NSWorkspace.shared.urlForApplication(
                                withBundleIdentifier: "com.apple.Terminal"
                            ) {
                                NSWorkspace.shared.open(terminal)
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                        if copiedGuideCommand == ExternalDependencyInstaller.officialBrewInstallCommand {
                            Label("命令已复制", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 7) {
                    Text("安装完成后")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Apple Silicon 的默认安装目录是 /opt/homebrew。安装完成后先点击下方「重新检测」。如果终端仍提示 brew: command not found，可按安装程序提示设置 Shell 环境：")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ExternalDependencyInstaller.appleSiliconShellenvCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                    HStack(spacing: 8) {
                        Button("复制环境配置命令") {
                            copyGuideCommand(ExternalDependencyInstaller.appleSiliconShellenvCommand)
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        Button("重新检测 Homebrew") { store.refresh() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        if copiedGuideCommand == ExternalDependencyInstaller.appleSiliconShellenvCommand {
                            Label("命令已复制", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                    Text("上面的 eval 只作用于当前终端会话；若希望今后自动生效，请按 Homebrew 安装完成时显示的提示将 shellenv 添加到 ~/.zprofile。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 15 {
                    Label(
                        "注意：Homebrew 官方当前主要支持 macOS 15 及更新系统；此 Mac 的系统版本较旧，安装可能失败或不受官方支持。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copyGuideCommand(_ command: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(command, forType: .string) {
            copiedGuideCommand = command
        }
    }

    private func openOfficialURL(_ value: String) {
        if let url = URL(string: value) { NSWorkspace.shared.open(url) }
    }

    private func confirmInstall(_ dependency: ExternalDependency) {
        guard store.installed[dependency] == nil,
              let brew = store.brewPath, !isBusy else { return }
        let dialog = NSAlert()
        dialog.messageText = "安装 \(dependency.title)？"
        dialog.informativeText = """
        将在当前 Mac 上执行：
        \(ExternalDependencyInstaller.command(for: dependency, brewPath: brew).joined(separator: " "))

        安装由 Homebrew 从第三方软件源下载并写入用户已有的 Homebrew 目录。LightIsle 不使用 sudo，也不会配置开机启动。
        """
        dialog.alertStyle = .informational
        dialog.addButton(withTitle: "确认安装")
        dialog.addButton(withTitle: "取消")
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        showInstallLog = false
        store.install(dependency)
    }
}
