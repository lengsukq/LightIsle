import SwiftUI

struct IntroAnimationView: View {
    var isReplay: Bool = false
    var onComplete: () -> Void
    @Environment(\.isleReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var featuresAppeared = false

    private let highlights: [(icon: String, title: String)] = [
        ("externaldrive.fill.badge.checkmark", "本地优先 · 数据不出盘"),
        ("person.2.fill", "家庭空间 · 独立配额"),
        ("wifi", "局域网与远程直连")
    ]

    var body: some View {
        ZStack {
            IsleBackdrop()
            VStack(spacing: 26) {
                Spacer(minLength: 24)
                BrandMark(size: 100)
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.88)
                    .opacity(appeared || reduceMotion ? 1 : 0)
                VStack(spacing: 12) {
                    Text("欢迎来到轻屿").font(.system(size: 32, weight: .semibold))
                    Text("自己的文件，安心放在自己的 Mac 上。")
                        .font(.system(size: 16)).foregroundStyle(IsleTheme.secondaryText)
                    Text("管理存储与连接，让家人的设备随时顺畅访问。")
                        .font(.system(size: 13)).foregroundStyle(IsleTheme.secondaryText)
                }
                .offset(y: appeared || reduceMotion ? 0 : 14)
                .opacity(appeared || reduceMotion ? 1 : 0)

                HStack(spacing: 10) {
                    ForEach(Array(highlights.enumerated()), id: \.offset) { index, item in
                        Label(item.title, systemImage: item.icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(IsleTheme.secondaryText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .modifier(IsleGlassBarSurface(cornerRadius: 16))
                            .offset(y: featuresAppeared || reduceMotion ? 0 : 10)
                            .opacity(featuresAppeared || reduceMotion ? 1 : 0)
                            .animation(
                                reduceMotion ? nil : IsleMotion.fluid.delay(Double(index) * 0.06),
                                value: featuresAppeared
                            )
                    }
                }

                Spacer(minLength: 24)
                HStack(spacing: 14) {
                    if isReplay {
                        Button("关闭预览", action: onComplete)
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .large))
                            .keyboardShortcut(.defaultAction)
                            .keyboardShortcut(.cancelAction)
                    } else {
                        Button("开始配置轻屿", action: onComplete)
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .large))
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .opacity(featuresAppeared || reduceMotion ? 1 : 0)
                .padding(.bottom, 36)
            }.padding(24)
        }
        .task {
            guard !reduceMotion else {
                appeared = true
                featuresAppeared = true
                return
            }
            withAnimation(IsleMotion.reveal) { appeared = true }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            withAnimation(IsleMotion.fluid) { featuresAppeared = true }
        }
    }
}
