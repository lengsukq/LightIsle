import SwiftUI
import AppKit

/// Stable project brand asset shared by the intro, native console and .app.
struct BrandMark: View {
    let size: CGFloat

    private static let cachedLogo: NSImage? = {
        if let url = Bundle.main.url(forResource: "LightIsleLogo", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        return NSImage(contentsOfFile: "apps/macos/Resources/LightIsleLogo.png")
    }()

    var body: some View {
        Group {
            if let icon = Self.cachedLogo {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                // Development runs outside the packaged .app still show the
                // same geometry family instead of an empty placeholder.
                Image(systemName: "sparkles")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .blue, .purple],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("轻屿 LightIsle")
    }
}
