import SwiftUI
import AppKit

extension ContentView {
    var settingsGroup5: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(preferenceSection: .notifications, title: "通知渠道（Bark、邮件、企业微信、钉钉）", footer: "磁盘、下载与自动化执行事件可按渠道外发。密钥只存 Mac 钥匙串，经私有 IPC 交给 Core 使用；Web 只显示已配置渠道，不返回凭据。") {
                AppleSettingsRow(title: "通道状态", icon: "bell.badge", iconTint: .red) {
                    HStack(spacing: 8) {
                        if model.notifyBusy {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.notifyConfigured ? "已配置（Core 已接收）" : (model.hasSavedNotifySecret ? "已保存在钥匙串，等待 Core 确认" : "未配置"))
                            .font(.caption)
                            .foregroundStyle(model.notifyConfigured ? .green : .secondary)
                        if let stats = model.notifyStats, stats.configured {
                            Text(stats.backingOff
                                 ? "通道连续失败，已暂停 5 分钟"
                                 : "队列 \(stats.queued) · 累计丢弃 \(stats.dropped)")
                                .font(.caption2).foregroundStyle(IsleTheme.secondaryText)
                        }
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "Bark 服务器", subtitle: "留空使用 https://api.day.app；仅填源地址，不带路径。", icon: "iphone", iconTint: .orange) {
                    TextField("https://api.day.app", text: $notifyBarkServerDraft)
                        .liquidInput()
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: settingsControlWidth)
                }
                AppleSettingsRow(title: "Bark 设备 Key", subtitle: "Bark App 内复制的 Key；不会在界面上回显已保存的值。", icon: "key.fill", iconTint: .indigo) {
                    SecureField("粘贴设备 Key…", text: $notifyBarkKeyDraft)
                        .liquidInput()
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: settingsControlWidth)
                }
                AppleSettingsRow(title: "通用 Webhook", subtitle: "自建服务 POST JSON 接口。企业微信和钉钉请使用下方独立的机器人协议。", icon: "arrowshape.turn.up.right", iconTint: .blue) {
                    TextField("https://example.com/hook", text: $notifyWebhookDraft)
                        .liquidInput()
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: settingsControlWidth)
                }
                AppleSettingsRow(title: "允许内网目标", subtitle: "自建 Bark/Webhook 部署在内网时勾选；默认拒绝内网与本机回环地址。", icon: "network.badge.shield.half.filled", iconTint: .gray) {
                    Toggle("", isOn: $notifyAllowPrivateDraft)
                        .labelsHidden()
                        .controlSize(.small)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "企业微信机器人", subtitle: "企业微信群机器人提供的完整 Webhook URL。", icon: "person.3", iconTint: .green) {
                    TextField("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=…", text: $notifyWecomDraft)
                        .liquidInput()
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: settingsControlWidth)
                }
                AppleSettingsRow(title: "钉钉机器人", subtitle: "钉钉群自定义机器人 Webhook URL。", icon: "bubble.left.and.bubble.right", iconTint: .blue) {
                    TextField("https://oapi.dingtalk.com/robot/send?access_token=…", text: $notifyDingtalkDraft)
                        .liquidInput()
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: settingsControlWidth)
                }
                AppleSettingsRow(title: "钉钉加签密钥（可选）", subtitle: "留空保留已保存的加签密钥。", icon: "lock.shield", iconTint: .indigo) {
                    SecureField("SEC…", text: $notifyDingtalkSecretDraft)
                        .liquidInput()
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: settingsControlWidth)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "邮件服务器", subtitle: "SMTP 仅允许 465（TLS）或 587（STARTTLS），不支持明文连接。", icon: "envelope", iconTint: .orange) {
                    HStack(spacing: 8) {
                        TextField("smtp.example.com", text: $notifySMTPHostDraft)
                            .liquidInput()
                            .font(.system(size: 12, design: .monospaced))
                        TextField("465", text: $notifySMTPPortDraft)
                            .liquidInput()
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 68)
                    }
                    .frame(width: settingsControlWidth)
                }
                AppleSettingsRow(title: "SMTP 登录", subtitle: "账户及授权码。密码留空则沿用钥匙串中已有值。", icon: "key.fill", iconTint: .indigo) {
                    HStack(spacing: 8) {
                        TextField("SMTP 用户名", text: $notifySMTPUserDraft)
                            .liquidInput()
                            .font(.system(size: 12))
                        SecureField("SMTP 授权码", text: $notifySMTPPasswordDraft)
                            .liquidInput()
                            .font(.system(size: 12))
                    }
                    .frame(width: settingsControlWidth)
                }
                AppleSettingsRow(title: "发件人与收件人", subtitle: "收件人可输入多个邮箱，以英文逗号分隔，最多 5 个。", icon: "envelope.badge", iconTint: .blue) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("发件邮箱", text: $notifySMTPFromDraft)
                            .liquidInput()
                            .font(.system(size: 12))
                        TextField("收件邮箱，例如 a@example.com,b@example.com", text: $notifySMTPToDraft)
                            .liquidInput()
                            .font(.system(size: 12))
                    }
                    .frame(width: settingsControlWidth)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "保存与测试", icon: "paperplane", iconTint: .green) {
                    HStack(spacing: 8) {
                        Button("取消修改") { resetNotificationDraft() }.buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        Button("保存通道") {
                            saveNotificationDraft()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(notifyBarkKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && notifyWebhookDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && notifyWecomDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && notifyDingtalkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && notifySMTPHostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && !(model.notifyConfigured || model.hasSavedNotifySecret))
                        Button("发送测试") { model.testNotify() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(!model.notifyConfigured)
                        if model.notifyConfigured || model.hasSavedNotifySecret {
                            Button("清除") { model.clearNotify() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                    }
                }
                if let result = model.notifyTestResult {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "测试结果", icon: "checkmark.seal", iconTint: .green) {
                        Text(result).font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
                if let error = model.notifyError {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "配置失败", icon: "exclamationmark.triangle", iconTint: .orange) {
                        Text(error).font(.caption).foregroundStyle(IsleTheme.warningText)
                    }
                }
                if model.state != .online {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "Core 未连接", icon: "wifi.slash", iconTint: .orange) {
                        Text("通道配置已保存在本机钥匙串，Core 就绪后会自动下发。")
                            .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
            }
            .task {
                guard !notificationDraftLoaded else { return }
                notificationDraftLoaded = true
                model.refreshNotifyStatus()
                if let saved = (model.isPresentationPreview ? nil : NotifySecretVault.load()) {
                    notifyBarkServerDraft = saved.barkServer
                    notifyWebhookDraft = saved.webhookURL
                    notifyAllowPrivateDraft = saved.allowPrivateTargets
                    notifyWecomDraft = saved.wecomWebhook ?? ""
                    notifyDingtalkDraft = saved.dingtalkWebhook ?? ""
                    notifySMTPHostDraft = saved.smtpHost ?? ""
                    notifySMTPPortDraft = String(saved.smtpPort ?? 465)
                    notifySMTPUserDraft = saved.smtpUsername ?? ""
                    notifySMTPFromDraft = saved.smtpFrom ?? ""
                    notifySMTPToDraft = saved.smtpTo ?? ""
                }
                notificationBaseline = notificationFields
            }
            .onChange(of: model.state) { _, newState in
                if newState == .online { model.refreshNotifyStatus() }
            }
        }
    }
}
