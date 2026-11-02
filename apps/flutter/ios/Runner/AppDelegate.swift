import Flutter
import UIKit
import AVKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var sessionVault: SessionVault?
  private var exportChannel: FlutterMethodChannel?
  private var exporting = false
  private var discoveryChannel: FlutterMethodChannel?
  private var discoveryHandler: IOSBonjourDiscovery?
  private var photoBackupHandler: IOSPhotoBackup?
  private var nativeVideoChannel: FlutterMethodChannel?
  private var nativeVideoController: AVPlayerViewController?

  deinit {
    discoveryHandler?.cancelActive()
    photoBackupHandler?.stop()
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    sessionVault = SessionVault(messenger: engineBridge.applicationRegistrar.messenger())
    discoveryHandler?.cancelActive()
    discoveryChannel?.setMethodCallHandler(nil)
    discoveryHandler = nil
    discoveryChannel = nil
    photoBackupHandler?.stop()
    photoBackupHandler = IOSPhotoBackup(messenger: engineBridge.applicationRegistrar.messenger())

    let videoChannel = FlutterMethodChannel(
      name: "lightisle/native-video",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    nativeVideoChannel = videoChannel
    videoChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "openLocal" else { result(FlutterMethodNotImplemented); return }
      guard let self,
            let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String,
            !path.isEmpty else {
        result(FlutterError(code: "invalid_local_video", message: "本地视频路径无效。", details: nil))
        return
      }
      let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
      let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
      guard url.isFileURL, url.path.hasPrefix(home),
            FileManager.default.fileExists(atPath: url.path) else {
        result(FlutterError(code: "invalid_local_video", message: "只允许播放应用已保存的本地视频。", details: nil))
        return
      }
      guard let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }),
        let window = scene.windows.first(where: { $0.isKeyWindow }),
        var presenter = window.rootViewController else {
        result(FlutterError(code: "native_player_unavailable", message: "请在应用前台打开系统播放器。", details: nil))
        return
      }
      while let presented = presenter.presentedViewController {
        presenter = presented
      }
      do {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
      } catch {
        result(FlutterError(code: "audio_session_unavailable", message: "无法启动系统播放会话。", details: nil))
        return
      }
      let player = AVPlayer(url: url)
      player.allowsExternalPlayback = true
      let controller = AVPlayerViewController()
      controller.player = player
      controller.allowsPictureInPicturePlayback = true
      controller.canStartPictureInPictureAutomaticallyFromInline = true
      controller.modalPresentationStyle = .fullScreen
      // Make AirPlay selection explicit for locally downloaded originals.
      // The AVPlayer route stays owned by the native system; Flutter never
      // tries to forward cookies or rewrite stream URLs to a receiver.
      if let overlay = controller.contentOverlayView {
        let routePicker = AVRoutePickerView(frame: .zero)
        routePicker.translatesAutoresizingMaskIntoConstraints = false
        routePicker.tintColor = .white
        routePicker.activeTintColor = .systemBlue
        overlay.addSubview(routePicker)
        NSLayoutConstraint.activate([
          routePicker.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -20),
          routePicker.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 12),
          routePicker.widthAnchor.constraint(equalToConstant: 44),
          routePicker.heightAnchor.constraint(equalToConstant: 44),
        ])
      }
      self.nativeVideoController?.player?.pause()
      self.nativeVideoController = controller
      presenter.present(controller, animated: true) {
        player.play()
      }
      result(true)
    }

    let channel = FlutterMethodChannel(name: "lightisle/export", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    exportChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "exportFile" || call.method == "exportFiles" else {
        result(FlutterMethodNotImplemented); return
      }
      guard let self else { result(FlutterError(code: "export_unavailable", message: "请重新打开应用后再试。", details: nil)); return }
      guard !self.exporting else { result(FlutterError(code: "export_busy", message: "请先完成当前文件导出。", details: nil)); return }
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "invalid_export", message: "待导出文件无效。", details: nil)); return
      }
      let root = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
      let paths: [String]
      if call.method == "exportFiles" {
        guard let items = args["files"] as? [[String: Any]],
              !items.isEmpty, items.count <= 20,
              items.allSatisfy({ ($0["path"] as? String)?.isEmpty == false }) else {
          result(FlutterError(code: "invalid_export", message: "批量导出最多 20 个有效文件。", details: nil))
          return
        }
        paths = items.compactMap { $0["path"] as? String }
      } else {
        guard let path = args["path"] as? String, !path.isEmpty else {
          result(FlutterError(code: "invalid_export", message: "待导出文件无效。", details: nil))
          return
        }
        paths = [path]
      }
      let sources = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
      guard sources.count == paths.count,
            sources.allSatisfy({ $0.path.hasPrefix(root) && FileManager.default.fileExists(atPath: $0.path) }) else {
        result(FlutterError(code: "invalid_export", message: "无法读取部分待导出的文件，请重新下载。", details: nil)); return
      }
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first(where: { $0.isKeyWindow }),
            var presenter = window.rootViewController else {
        result(FlutterError(code: "export_unavailable", message: "请在应用前台导出文件。", details: nil)); return
      }
      while let presented = presenter.presentedViewController { presenter = presented }
      let sheet = UIActivityViewController(activityItems: sources, applicationActivities: nil)
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

    let discovery = IOSBonjourDiscovery()
    discoveryHandler = discovery
    let discoveryChannel = FlutterMethodChannel(name: "lightisle/discovery", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    self.discoveryChannel = discoveryChannel
    discoveryChannel.setMethodCallHandler { [weak self] call, result in
      guard let handler = self?.discoveryHandler else {
        result(FlutterError(code: "discovery_unavailable", message: "请重新打开应用后重试局域网发现。", details: nil))
        return
      }
      handler.handle(call, result: result)
    }
  }
}
