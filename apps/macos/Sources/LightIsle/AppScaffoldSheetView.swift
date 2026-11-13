import SwiftUI

struct AppScaffoldSheetView: View {
    @ObservedObject var appsCenter: NativeAppsModel
    @Binding var isPresented: Bool

    @State private var idText = ""
    @State private var nameText = ""
    @State private var descriptionText = ""
    @State private var category = "utility"
    @State private var mode = "on-demand"
    @State private var runtime = "python"
    @State private var locationID = ""
    @State private var hasCron = false
    @State private var cronExpr = "0 * * * *"
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("新建轻应用插件脚手架")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AppleSettingsGroup(
                        title: "基本信息与运行模式",
                        footer: "将自动在 plugins/<id> 下生成 plugin.json、icon.svg、env.json 与对应语言的可执行入口脚本。"
                    ) {
                        AppleSettingsRow(title: "插件 ID", subtitle: "小写字母与数字短横线，例如 family-board", icon: "tag", iconTint: .blue) {
                            TextField("family-board", text: $idText)
                                .liquidInput()
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 240)
                        }
                        IsleGroupSpacing(height: 4).padding(.leading, 14)
                        AppleSettingsRow(title: "显示名称", icon: "textformat", iconTint: .indigo) {
                            TextField("家庭留言板", text: $nameText)
                                .liquidInput()
                                .frame(width: 240)
                        }
                        IsleGroupSpacing(height: 4).padding(.leading, 14)
                        AppleSettingsRow(title: "简介说明", icon: "doc.plaintext", iconTint: .teal) {
                            TextField("可选简介…", text: $descriptionText)
                                .liquidInput()
                                .frame(width: 240)
                        }
                        if let locations = appsCenter.appStorage?.locations, locations.count > 1 {
                            IsleGroupSpacing(height: 4).padding(.leading, 14)
                            AppleSettingsRow(title: "应用存储位置", icon: "externaldrive", iconTint: .blue) {
                                Picker("应用存储位置", selection: $locationID) {
                                    Text("跟随默认（\(locations.first(where: { $0.isDefault })?.name ?? "Mac 内置盘")）").tag("")
                                    ForEach(locations) { loc in
                                        Text("\(loc.kind == "external" ? "其他盘" : "内置盘") · \(loc.name)\(loc.online ? "" : "（离线）")").tag(loc.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 220)
                            }
                        }
                        IsleGroupSpacing(height: 4).padding(.leading, 14)
                        AppleSettingsRow(title: "Web 模式", icon: "globe", iconTint: .purple) {
                            Picker("Web 模式", selection: $mode) {
                                Text("按需唤醒 (on-demand)").tag("on-demand")
                                Text("常驻后台 (persistent)").tag("persistent")
                                Text("纯静态网页 (static)").tag("static")
                                Text("仅定时任务 (none)").tag("none")
                            }
                            .labelsHidden()
                            .frame(width: 220)
                            .onChange(of: mode) { _, next in
                                if next == "static" { runtime = "static" }
                                else if runtime == "static" { runtime = "python" }
                                if next == "none" { hasCron = true }
                            }
                        }
                        if mode != "static" {
                            IsleGroupSpacing(height: 4).padding(.leading, 14)
                            AppleSettingsRow(title: "脚本运行环境", icon: "terminal", iconTint: .orange) {
                                Picker("Runtime", selection: $runtime) {
                                    Text("Python 3").tag("python")
                                    Text("Node.js").tag("node")
                                    Text("Go").tag("go")
                                    Text("Shell").tag("shell")
                                }
                                .labelsHidden()
                                .frame(width: 220)
                            }
                        }
                        IsleGroupSpacing(height: 4).padding(.leading, 14)
                        AppleSettingsRow(title: "包含定时任务 (Cron)", icon: "clock.arrow.2.circlepath", iconTint: .green) {
                            HStack(spacing: 10) {
                                Toggle("", isOn: $hasCron)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .disabled(mode == "none")
                                if hasCron {
                                    TextField("0 * * * *", text: $cronExpr)
                                        .liquidInput()
                                        .font(.system(size: 12, design: .monospaced))
                                        .frame(width: 150)
                                }
                            }
                        }
                    }

                    if let validationError {
                        Text(validationError)
                            .font(.caption)
                            .foregroundStyle(IsleTheme.warningText)
                    }
                }
                .padding(.vertical, 2)
            }

            Divider()

            HStack(spacing: 10) {
                Spacer()
                Button("取消") { isPresented = false }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .regular))
                    .keyboardShortcut(.cancelAction)
                Button("创建并激活插件") {
                    createScaffold()
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                .keyboardShortcut(.defaultAction)
                .disabled(appsCenter.busy)
            }
        }
        .padding(22)
        .frame(minWidth: 560, idealWidth: 600, maxWidth: 640, minHeight: 380, idealHeight: 460, maxHeight: 540)
    }

    private func createScaffold() {
        let trimmedID = idText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedName.isEmpty else {
            validationError = "请填写插件 ID 与显示名称。"
            return
        }
        validationError = nil
        appsCenter.scaffoldApp(NativeAppScaffoldPayload(
            id: trimmedID,
            name: trimmedName,
            description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            mode: mode,
            runtime: mode == "static" ? "static" : runtime,
            locationId: locationID.isEmpty ? nil : locationID,
            hasCron: hasCron || mode == "none",
            cron: cronExpr.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        isPresented = false
    }
}
