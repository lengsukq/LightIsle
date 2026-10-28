import SwiftUI

/// Debug-only display overrides apply to the isolated preview window, never
/// the owner's macOS settings. The shipping app always follows the system.
struct NativePresentationPreview: ViewModifier {
    @Environment(\.isleReduceMotion) private var reduceMotion
    @Environment(\.isleReduceTransparency) private var reduceTransparency
    @Environment(\.isleContrast) private var contrast
    @ViewBuilder func body(content: Content) -> some View {
        #if DEBUG
        if AppModel.shared.isPresentationPreview {
            content
                .preferredColorScheme(option("Appearance") == "dark" ? .dark : option("Appearance") == "light" ? .light : nil)
                .environment(\.isleReduceMotion, reduceMotion || option("ReducedMotion") == "true")
                .environment(\.isleReduceTransparency, reduceTransparency || option("Opaque") == "true")
                .environment(\.isleContrast, option("Contrast") == "high" ? .increased : contrast)
        } else { content }
        #else
        content
        #endif
    }
    private func option(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: "LightIsleDesign" + key) as? String
    }
}

enum NativeWindowSize {
    static var width: CGFloat { value("Width", fallback: 1120) }
    static var height: CGFloat { value("Height", fallback: 730) }
    private static func value(_ name: String, fallback: CGFloat) -> CGFloat {
        #if DEBUG
        if Bundle.main.object(forInfoDictionaryKey: "LightIsleDesignPreview") as? Bool == true,
           let value = Bundle.main.object(forInfoDictionaryKey: "LightIsleDesign" + name) as? Double { return value }
        #endif
        return fallback
    }
}
