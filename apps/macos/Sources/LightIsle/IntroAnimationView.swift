import SwiftUI

struct IntroAnimationView: View {
    var onComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Int = 0
    @State private var glowPulse: Bool = false
    @State private var shimmerOffset: CGFloat = -200

    var body: some View {
        ZStack {
            // Ambient animated mesh / glow background
            ambientBackground

            VStack(spacing: 28) {
                Spacer()

                // Hero Frosted Glass Badge with Shimmer
                ZStack {
                    // Outer ambient glow
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.blue.opacity(glowPulse ? 0.35 : 0.15),
                                    Color.cyan.opacity(glowPulse ? 0.2 : 0.05),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 20,
                                endRadius: 130
                            )
                        )
                        .frame(width: 260, height: 260)
                        .blur(radius: 20)

                    // Brand artwork is an actual reusable asset. Finder, Dock,
                    // Web and this animation now share exactly the same mark.
                    BrandMark(size: 140)
                        .shadow(color: Color.black.opacity(0.12), radius: 24, x: 0, y: 12)
                        .shadow(color: Color.blue.opacity(0.18), radius: 36, x: 0, y: 18)
                        .overlay(
                            // Shimmer highlight sweep
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [.clear, .white.opacity(0.4), .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .rotationEffect(.degrees(30))
                                .offset(x: shimmerOffset)
                                .mask(BrandMark(size: 140))
                        )
                }
                .scaleEffect(phase >= 1 ? 1.0 : 0.6)
                .opacity(phase >= 1 ? 1.0 : 0.0)

                // Brand Title & Slogan
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text("轻屿")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.primary, Color.primary.opacity(0.85)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        Text("LightIsle")
                            .font(.system(size: 34, weight: .light, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .opacity(phase >= 2 ? 1.0 : 0.0)
                    .offset(y: phase >= 2 ? 0 : 16)

                    Text("让每一份珍贵，都有自己的栖息之地。")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .opacity(phase >= 2 ? 1.0 : 0.0)
                        .offset(y: phase >= 2 ? 0 : 12)
                }

                Spacer()

                // Continue Button / Skip
                HStack(spacing: 16) {
                    Button {
                        completeAnimation()
                    } label: {
                        HStack(spacing: 8) {
                            Text("开启私人空间")
                                .fontWeight(.semibold)
                            Image(systemName: "arrow.right")
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(
                                colors: [Color.blue, Color(red: 0.1, green: 0.45, blue: 0.95)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .shadow(color: Color.blue.opacity(0.35), radius: 12, x: 0, y: 6)
                    }
                    .buttonStyle(.plain)
                    .opacity(phase >= 3 ? 1.0 : 0.0)
                    .offset(y: phase >= 3 ? 0 : 14)
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            runAnimationSequence()
        }
    }

    private var ambientBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            // Dynamic soft light blobs
            Circle()
                .fill(Color.blue.opacity(0.12))
                .frame(width: 480, height: 480)
                .offset(x: glowPulse ? -120 : -80, y: glowPulse ? -100 : -60)
                .blur(radius: 60)

            Circle()
                .fill(Color.purple.opacity(0.08))
                .frame(width: 420, height: 420)
                .offset(x: glowPulse ? 140 : 100, y: glowPulse ? 120 : 80)
                .blur(radius: 60)
        }
        .ignoresSafeArea()
    }

    private func runAnimationSequence() {
        if reduceMotion {
            phase = 3
            return
        }

        withAnimation(.easeOut(duration: 0.8)) {
            phase = 1
        }
        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
            glowPulse = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
                phase = 2
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 1.0)) {
                shimmerOffset = 200
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                phase = 3
            }
        }
    }

    private func completeAnimation() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            onComplete()
        }
    }
}
