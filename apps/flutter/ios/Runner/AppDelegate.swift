import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var exportChannel: FlutterMethodChannel?
  private var exporting = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(name: "lightisle/export", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    exportChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "exportFile" else { result(FlutterMethodNotImplemented); return }
      guard let self else { result(FlutterError(code: "export_unavailable", message: "请重新打开应用后再试。", details: nil)); return }
      guard !self.exporting else { result(FlutterError(code: "export_busy", message: "请先完成当前文件导出。", details: nil)); return }
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterError(code: "invalid_export", message: "待导出文件无效。", details: nil)); return
      }
      let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
      let root = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
      guard source.path.hasPrefix(root), FileManager.default.fileExists(atPath: source.path) else {
        result(FlutterError(code: "invalid_export", message: "无法读取待导出的文件，请重新下载。", details: nil)); return
      }
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first(where: { $0.isKeyWindow }),
            var presenter = window.rootViewController else {
        result(FlutterError(code: "export_unavailable", message: "请在应用前台导出文件。", details: nil)); return
      }
      while let presented = presenter.presentedViewController { presenter = presented }
      let sheet = UIActivityViewController(activityItems: [source], applicationActivities: nil)
      if let popover = sheet.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
      }
      self.exporting = true
      sheet.completionWithItemsHandler = { [weak self] _, completed, _, error in
        self?.exporting = false
        if error != nil { result(FlutterError(code: "export_failed", message: "导出失败，请检查目标位置与存储空间。", details: nil)) }
        else { result(completed ? "shared" : nil) }
      }
      presenter.present(sheet, animated: true)
    }
  }
}
