import Cocoa
import FlutterMacOS
import AVKit

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var sessionVault: SessionVault?
  private var desktopFolderBookmarks: DesktopFolderBookmarkPlugin?
  private var offlineVideoWindow: NSWindow?
  private var offlinePlayer: AVPlayer?
  private var nativeVideoChannel: FlutterMethodChannel?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Use a single unified title/toolbar surface instead of stacking a
    // separate AppKit title row above Flutter's navigation bar. AppKit still
    // owns the standard traffic lights, fullscreen and window-resize behavior.
    self.styleMask.insert(.fullSizeContentView)
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    // Only the Flutter toolbar drag surface invokes performDrag via channel so
    // modals, photo viewers, and fullscreen controls in the top strip are
    // never swallowed by an overlapping AppKit subview.
    self.isMovableByWindowBackground = false
    self.title = "轻屿 LightIsle"

    RegisterGeneratedPlugins(registry: flutterViewController)
    sessionVault = SessionVault(messenger: flutterViewController.engine.binaryMessenger)
    desktopFolderBookmarks = DesktopFolderBookmarkPlugin(
      messenger: flutterViewController.engine.binaryMessenger,
      window: self
    )

    let videoChannel = FlutterMethodChannel(
      name: "lightisle/native-video",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    nativeVideoChannel = videoChannel
    videoChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      if call.method == "startWindowDrag" {
        if !self.styleMask.contains(.fullScreen), let event = NSApp.currentEvent {
          self.performDrag(with: event)
        }
        result(true)
        return
      }
      if call.method == "doubleClickTitlebar" {
        if !self.styleMask.contains(.fullScreen) {
          let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
          if action == "Minimize" {
            self.miniaturize(nil)
          } else if action != "None" {
            self.performZoom(nil)
          }
        }
        result(true)
        return
      }
      if call.method == "toggleFullScreen" {
        self.toggleFullScreen(nil)
        result(!self.styleMask.contains(.fullScreen))
        return
      }
      if call.method == "exitFullScreen" {
        if self.styleMask.contains(.fullScreen) {
          self.toggleFullScreen(nil)
        }
        result(false)
        return
      }
      guard call.method == "openLocal" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
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
    if let closing = notification.object as? NSWindow, closing === self {
      desktopFolderBookmarks?.releaseAll()
    }
    guard let window = notification.object as? NSWindow,
          window === offlineVideoWindow else { return }
    offlinePlayer?.pause()
    offlinePlayer = nil
    offlineVideoWindow = nil
  }
}
