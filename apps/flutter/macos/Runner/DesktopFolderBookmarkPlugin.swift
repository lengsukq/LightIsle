import Cocoa
import FlutterMacOS

/// Read-only security-scoped folder bookmark bridge for macOS client backups.
/// The client never requests write scope for source folders being backed up.
final class DesktopFolderBookmarkPlugin {
  private let channel: FlutterMethodChannel
  private weak var hostWindow: NSWindow?
  private var activeScopes: [String: URL] = [:]

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    self.hostWindow = window
    self.channel = FlutterMethodChannel(
      name: "lightisle/desktop-folders",
      binaryMessenger: messenger
    )
    self.channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "plugin_unavailable", message: "目录授权服务已关闭。", details: nil))
        return
      }
      self.handle(call, result: result)
    }
  }

  deinit {
    releaseAll()
  }

  func releaseAll() {
    let urls = Array(activeScopes.values)
    activeScopes.removeAll()
    for url in urls {
      url.stopAccessingSecurityScopedResource()
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickDirectory":
      let panel = NSOpenPanel()
      panel.title = "选择要备份到 NAS 的本机文件夹"
      panel.prompt = "选择文件夹"
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = false
      panel.resolvesAliases = false

      let completion: (NSApplication.ModalResponse) -> Void = { response in
        guard response == .OK, let url = panel.url else {
          result(nil)
          return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
          result(FlutterError(code: "invalid_directory", message: "所选路径不是有效文件夹。", details: nil))
          return
        }
        do {
          let bookmark = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
          )
          result([
            "path": url.path,
            "name": url.lastPathComponent,
            "bookmark": bookmark.base64EncodedString(),
          ])
        } catch {
          // Non-sandboxed debug builds or volumes that do not require security
          // bookmarks still allow direct read access within the session.
          result([
            "path": url.path,
            "name": url.lastPathComponent,
            "bookmark": "",
          ])
        }
      }

      if let window = hostWindow {
        panel.beginSheetModal(for: window, completionHandler: completion)
      } else {
        completion(panel.runModal())
      }

    case "startAccess":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "invalid_arguments", message: "目录授权参数无效。", details: nil))
        return
      }
      let rawBookmark = (args["bookmark"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let fallbackPath = (args["path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if rawBookmark.isEmpty {
        var isDir: ObjCBool = false
        guard !fallbackPath.isEmpty,
              FileManager.default.fileExists(atPath: fallbackPath, isDirectory: &isDir),
              isDir.boolValue,
              FileManager.default.isReadableFile(atPath: fallbackPath) else {
          result(FlutterError(
            code: "folder_permission_expired",
            message: "该本机文件夹需要重新选择授权后才能读取。",
            details: nil
          ))
          return
        }
        result([
          "accessId": "",
          "path": fallbackPath,
        ])
        return
      }
      guard let bookmarkData = Data(base64Encoded: rawBookmark) else {
        result(FlutterError(code: "invalid_bookmark", message: "本机文件夹授权记录无效，请重新选择文件夹。", details: nil))
        return
      }
      var isStale = false
      do {
        let resolved = try URL(
          resolvingBookmarkData: bookmarkData,
          options: [.withSecurityScope, .withoutUI],
          relativeTo: nil,
          bookmarkDataIsStale: &isStale
        )
        let started = resolved.startAccessingSecurityScopedResource()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir),
              isDir.boolValue,
              FileManager.default.isReadableFile(atPath: resolved.path) else {
          if started { resolved.stopAccessingSecurityScopedResource() }
          result(FlutterError(
            code: "folder_unavailable",
            message: "本机源文件夹不存在或已失去读取权限，请检查外接设备或重新选择。",
            details: nil
          ))
          return
        }
        var refreshedBookmark: String?
        if isStale {
          if let fresh = try? resolved.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
          ) {
            refreshedBookmark = fresh.base64EncodedString()
          }
        }
        let accessId: String
        if started {
          accessId = UUID().uuidString
          activeScopes[accessId] = resolved
        } else {
          accessId = ""
        }
        var payload: [String: Any] = [
          "accessId": accessId,
          "path": resolved.path,
        ]
        if let refreshedBookmark {
          payload["refreshedBookmark"] = refreshedBookmark
        }
        result(payload)
      } catch {
        result(FlutterError(
          code: "folder_permission_expired",
          message: "本机文件夹访问授权已失效，请重新选择该文件夹。",
          details: nil
        ))
      }

    case "stopAccess":
      let args = call.arguments as? [String: Any]
      if let accessId = args?["accessId"] as? String, !accessId.isEmpty,
         let url = activeScopes.removeValue(forKey: accessId) {
        url.stopAccessingSecurityScopedResource()
      }
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
