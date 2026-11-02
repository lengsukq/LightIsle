import Cocoa
import FlutterMacOS
import AVKit

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var sessionVault: SessionVault?
  private var offlineVideoWindow: NSWindow?
  private var offlinePlayer: AVPlayer?
  private var nativeVideoChannel: FlutterMethodChannel?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    sessionVault = SessionVault(messenger: flutterViewController.engine.binaryMessenger)

    let videoChannel = FlutterMethodChannel(
      name: "lightisle/native-video",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    nativeVideoChannel = videoChannel
    videoChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "openLocal" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self,
            let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            !path.isEmpty else {
        result(FlutterError(code: "invalid_local_video", message: "本地视频路径无效。", details: nil))
        return
      }
      let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
      guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
        result(FlutterError(code: "invalid_local_video", message: "本地视频文件已不可用。", details: nil))
        return
      }
      self.offlinePlayer?.pause()
      self.offlineVideoWindow?.close()
      let player = AVPlayer(url: url)
      player.allowsExternalPlayback = true
      let playerView = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 860, height: 520))
      playerView.player = player
      playerView.controlsStyle = .floating
      playerView.allowsPictureInPicturePlayback = true
      let routePicker = AVRoutePickerView(frame: .zero)
      routePicker.translatesAutoresizingMaskIntoConstraints = false
      playerView.addSubview(routePicker)
      NSLayoutConstraint.activate([
        routePicker.trailingAnchor.constraint(equalTo: playerView.trailingAnchor, constant: -16),
        routePicker.topAnchor.constraint(equalTo: playerView.topAnchor, constant: 12),
        routePicker.widthAnchor.constraint(equalToConstant: 34),
        routePicker.heightAnchor.constraint(equalToConstant: 34),
      ])
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
      )
      window.contentView = playerView
      window.title = url.lastPathComponent
      window.delegate = self
      window.center()
      window.makeKeyAndOrderFront(nil)
      self.offlinePlayer = player
      self.offlineVideoWindow = window
      player.play()
      result(true)
    }

    super.awakeFromNib()
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
          window === offlineVideoWindow else { return }
    offlinePlayer?.pause()
    offlinePlayer = nil
    offlineVideoWindow = nil
  }
}
