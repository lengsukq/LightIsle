import SwiftUI

struct IntroAnimationView: View {
    var onComplete: () -> Void
    @Environment(\.isleReduceMotion) private var reduceMotion
    @State private var appeared = false
    var body: some View {
        ZStack {
            IsleBackdrop()
            VStack(spacing: 26) {
                Spacer(minLength: 24)
                BrandMark(size: 100)
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.9)
                    .opacity(appeared || reduceMotion ? 1 : 0)
                VStack(spacing: 12) {
                    Text("欢迎来到轻屿").font(.system(size: 32, weight: .semibold))
                    Text("自己的文件，安心放在自己的 Mac 上。")
                        .font(.system(size: 16)).foregroundStyle(IsleTheme.secondaryText)
                    Text("管理存储与连接，让家人的设备随时访问。")
                        .font(.system(size: 13)).foregroundStyle(IsleTheme.secondaryText)
                }
                .offset(y: appeared || reduceMotion ? 0 : 16)
                .opacity(appeared || reduceMotion ? 1 : 0)
                Spacer(minLength: 24)
                HStack(spacing: 14) {
                    Button("继续设置", action: onComplete).buttonStyle(LiquidButtonStyle(variant: .prominent, size: .large))
                        .keyboardShortcut(.defaultAction)
                    Button("跳过介绍", action: onComplete).buttonStyle(LiquidButtonStyle(variant: .borderless))
                }.padding(.bottom, 36)
            }.padding(24)
        }
        .task {
            guard !reduceMotion else { appeared = true; return }
            withAnimation(IsleMotion.reveal) { appeared = true }
        }
    }
}
