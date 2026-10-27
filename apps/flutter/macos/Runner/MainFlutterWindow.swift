import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var sessionVault: SessionVault?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    sessionVault = SessionVault(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
