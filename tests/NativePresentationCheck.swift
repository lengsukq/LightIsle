import AppKit
import SwiftUI

@main
struct NativePresentationCheck {
    @MainActor static func main() async {
        precondition(ManagementSection.allCases.count == 6)
        for page in SidebarPage.allCases {
            let primary = SidebarPage.primary(page.section)
            precondition(primary.section == page.section)
        }
        precondition([SidebarPage.files, .photos, .cinema].allSatisfy { $0.section == .spaces })
        precondition(SidebarPage.dependencies.section == .settings)
        precondition(Set(SidebarPage.allCases.filter { $0 != .spaces }.map { String($0.shortcut.character) }).count == 9)

        var state = DetailPreviewState()
        let a = UUID(), b = UUID()
        let old = state.invalidateDelay()
        let current = state.invalidateDelay()
        state.show(a, ticket: old)
        precondition(state.owner == nil, "stale hover opened a preview")
        state.show(b, ticket: current)
        precondition(state.owner == b)
        state.pin(b)
        let leave = state.invalidateDelay()
        state.dismiss(ticket: leave)
        precondition(state.owner == b && state.pinned, "pointer departure dismissed a pinned preview")
        state.pin(a)
        precondition(state.owner == a, "click could not transfer preview ownership")
        state.dismiss()
        state.show(b, ticket: current)
        precondition(state.owner == nil, "cancelled page preview reopened")
        for _ in 0..<100 {
            weak var released: DetailPreviewCoordinator?
            autoreleasepool {
                let coordinator = DetailPreviewCoordinator()
                released = coordinator
                coordinator.enter(a); coordinator.leave(a); coordinator.dismiss()
            }
            precondition(released == nil, "hover task retained its coordinator")
        }

        for invalid in ["NaN", "inf", "1e999", "-1", "1025", "1048577", "abc"] {
            precondition(NativeFormValidation.threshold(gib: invalid, percent: "5", priorMiB: 2048, priorPercent: 5) == nil)
        }
        precondition(NativeFormValidation.threshold(gib: "2", percent: "51", priorMiB: 2048, priorPercent: 5) == nil)
        precondition(NativeFormValidation.threshold(gib: "0", percent: "0", priorMiB: 2048, priorPercent: 5) == nil)
        precondition(NativeFormValidation.threshold(gib: "2.5", percent: "5", priorMiB: 2048, priorPercent: 5)?.0 == 2560)
        precondition(NativeFormValidation.threshold(gib: "", percent: "", priorMiB: 2048, priorPercent: 5)?.0 == 2048)

        let timed = DetailPreviewCoordinator()
        timed.enter(a)
        try? await Task.sleep(for: .milliseconds(200))
        precondition(timed.state.owner == nil, "preview opened before hover delay")
        try? await Task.sleep(for: .milliseconds(350))
        precondition(timed.state.owner == a, "hover preview did not open")
        timed.pin(a); timed.leave(a)
        try? await Task.sleep(for: .milliseconds(250))
        precondition(timed.state.owner == a && timed.state.pinned)
        timed.dismiss(); timed.enter(b); timed.dismiss()
        try? await Task.sleep(for: .milliseconds(500))
        precondition(timed.state.owner == nil, "cancelled delay reopened preview")
        print("PASS actual hover delay, pin retention, and cancellation")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        for width in [CGFloat(490), 780, 1044] {
            let view = AppleSettingsGroup(title: "镜像源") {
                AppleSettingsRow(title: "镜像加速服务", subtitle: "第三方公共服务，可能限流或更改政策；请勿用于私有镜像凭据。", icon: "globe") {
                    LiquidMenuPicker(title: "镜像加速服务", selection: .constant("sample"), options: [LiquidMenuOption(value: "sample", label: "毫秒镜像 · 公网候选")], minWidth: 190)
                }
                AppleSettingsRow(title: "配置操作", subtitle: "先确认配置内容，再执行操作。", icon: "gearshape") {
                    HStack { Button("测试连接") {}; Button("应用镜像源配置…") {}; Button("官方文档") {} }
                }
            }.frame(width: width).fixedSize(horizontal: false, vertical: true)
            let explanationRows = AppleSettingsGroup {
                AppleSettingsRow(title: "共享给其他 Mac", subtitle: "在「系统设置 → 通用 → 共享」中开启文件共享，并选择需要分享的文件夹。", icon: "folder") { EmptyView() }
                Divider()
                AppleSettingsRow(title: "允许其他 Mac 备份到这里", subtitle: "在系统文件共享中指定专用文件夹，并开启「作为时间机器备份目的地」。", icon: "clock") { EmptyView() }
            }.frame(width: width).fixedSize(horizontal: false, vertical: true)
            let explanation = NSHostingView(rootView: explanationRows).fittingSize
            precondition(explanation.height >= 110 && explanation.height < 260, "read-only rows compressed to \(explanation.height) at width \(width)")
            print("PASS read-only row layout width=\(Int(width)), height=\(Int(explanation.height))")
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            precondition(size.height > 60 && size.height < 350, "settings row expanded to \(size.height) at width \(width)")
            print("PASS settings layout width=\(Int(width)), height=\(Int(size.height))")
        }
        print("PASS six-section legacy routing, preview races/pinning/cancellation/lifetime, finite form validation, settings intrinsic height")
    }
}
