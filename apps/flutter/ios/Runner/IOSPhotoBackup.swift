import Flutter
import Foundation
import Photos
import Network

/// Foreground-only bridge. The source PHAssets are never changed or removed.
/// PHAssetResourceManager streams original bytes to an app-owned temporary
/// file; Flutter independently hashes them and the NAS validates them again.
final class IOSPhotoBackup {
    private let channel: FlutterMethodChannel
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "lightisle.ios.photos.network")
    private var connectedToWifi = false
    private var pending = Set<String>()
    private let stateQueue = DispatchQueue(label: "lightisle.ios.photos.state")
    private let temporaryDirectory: URL

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "lightisle/photos", binaryMessenger: messenger)
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightisle-photos", isDirectory: true)
        // Private temporary originals left by a force quit are not user
        // assets. Clean only the names we create, inside this app-owned path.
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory, includingPropertiesForKeys: nil) {
            for file in entries where file.lastPathComponent.hasSuffix(".asset") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.stateQueue.sync { self?.connectedToWifi = path.status == .satisfied && path.usesInterfaceType(.wifi) }
        }
        pathMonitor.start(queue: pathQueue)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(FlutterError(code: "photos_unavailable", message: "相册服务已关闭", details: nil))
                return
            }
            self.handle(call, result: result)
        }
    }

    func stop() {
        channel.setMethodCallHandler(nil)
        pathMonitor.cancel()
        stateQueue.sync { pending.removeAll() }
    }

    private func authorized() -> Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    private func error(_ code: String, _ message: String) -> FlutterError {
        FlutterError(code: code, message: message, details: nil)
    }

    private func assetID(_ identifier: String) -> String {
        Data(identifier.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func localIdentifier(_ encoded: String) -> String? {
        guard encoded.count <= 200,
              encoded.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        var value = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value), let name = String(data: data, encoding: .utf8),
              !name.isEmpty, name.count < 150 else { return nil }
        return name
    }

    private func fetch(includeVideos: Bool) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false),
            NSSortDescriptor(key: "localIdentifier", ascending: false),
        ]
        return includeVideos ? PHAsset.fetchAssets(with: options)
            : PHAsset.fetchAssets(with: .image, options: options)
    }

    private func version(_ assets: PHFetchResult<PHAsset>) -> String {
        let first = assets.count > 0 ? assets.object(at: 0) : nil
        let last = assets.count > 0 ? assets.object(at: assets.count - 1) : nil
        let firstTime = first?.modificationDate?.timeIntervalSince1970 ?? 0
        let lastTime = last?.modificationDate?.timeIntervalSince1970 ?? 0
        return "ios:" + String(assets.count) + ":" +
            (first?.localIdentifier ?? "") + ":" + String(firstTime) + ":" +
            (last?.localIdentifier ?? "") + ":" + String(lastTime)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "permission":
            result(authorized())
        case "requestPermission":
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async { result(status == .authorized) }
            }
        case "isWifi":
            result(stateQueue.sync { connectedToWifi })
        case "list":
            guard authorized() else {
                result(error("photo_permission_denied", "请授予全部照片读取权限，有限照片访问不适合完整备份。"))
                return
            }
            let args = call.arguments as? [String: Any] ?? [:]
            let limit = min(100, max(1, args["limit"] as? Int ?? 40))
            let includeVideos = args["includeVideos"] as? Bool ?? false
            let offsetString = args["beforeId"] as? String ?? ""
            guard offsetString.isEmpty || (offsetString.count <= 9 && offsetString.allSatisfy(\.isNumber)),
                  let offset = Int(offsetString.isEmpty ? "0" : offsetString), offset >= 0 else {
                result(error("invalid_cursor", "照片分页游标无效")); return
            }
            let assets = fetch(includeVideos: includeVideos)
            guard offset <= assets.count else {
                result(error("photo_library_changed", "相册内容发生变化，请从最新照片重新扫描")); return
            }
            let end = min(offset + limit, assets.count)
            var rows = [[String: Any]]()
            if end > offset {
                for i in offset..<end {
                    let asset = assets.object(at: i)
                    let resources = PHAssetResource.assetResources(for: asset)
                    let date = asset.modificationDate ?? asset.creationDate ?? .distantPast
                    var selected = [(String, PHAssetResource)]()
                    if asset.mediaType == .image {
                        if let photo = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }) {
                            // Preserve previous photo IDs and NAS names.
                            selected.append((assetID(asset.localIdentifier), photo))
                        }
                        if includeVideos && asset.mediaSubtypes.contains(.photoLive),
                           let paired = resources.first(where: { $0.type == .pairedVideo }) {
                            selected.append(("l." + assetID(asset.localIdentifier), paired))
                        }
                    } else if includeVideos && asset.mediaType == .video,
                              let video = resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo }) {
                        selected.append(("v." + assetID(asset.localIdentifier), video))
                    }
                    for (encoded, resource) in selected {
                        rows.append([
                            "id": encoded,
                            "name": resource.originalFilename,
                            "modified": Int64(date.timeIntervalSince1970),
                            // Original size is determined from the private copy.
                            "size": 0,
                            "generation": 0,
                        ])
                    }
                }
            }
            result([
                "items": rows,
                "nextCursor": end < assets.count ? String(end) : "",
                "version": version(assets),
            ])
        case "prepare":
            guard authorized() else {
                result(error("photo_permission_denied", "需要全部照片读取权限")); return
            }
            guard let args = call.arguments as? [String: Any],
                  let encoded = args["id"] as? String,
                  let requestID = args["requestId"] as? String,
                  requestID.count > 0 && requestID.count < 180 else {
                result(error("invalid_asset", "无效照片编号")); return
            }
            let includeVideos = args["includeVideos"] as? Bool ?? false
            let kind: String
            let resourceID: String
            if encoded.hasPrefix("l.") {
                kind = "live"
                resourceID = String(encoded.dropFirst(2))
            } else if encoded.hasPrefix("v.") {
                kind = "video"
                resourceID = String(encoded.dropFirst(2))
            } else {
                kind = "photo"
                resourceID = encoded
            }
            guard (kind == "photo" || includeVideos),
                  let identifier = localIdentifier(resourceID) else {
                result(error("invalid_asset", "无效或未授权的视频资源编号")); return
            }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            guard let asset = assets.firstObject,
                  let resource = PHAssetResource.assetResources(for: asset)
                    .first(where: { item in
                        switch kind {
                        case "live": return asset.mediaType == .image &&
                            asset.mediaSubtypes.contains(.photoLive) && item.type == .pairedVideo
                        case "video": return asset.mediaType == .video &&
                            (item.type == .video || item.type == .fullSizeVideo)
                        default: return asset.mediaType == .image &&
                            (item.type == .photo || item.type == .fullSizePhoto)
                        }
                    }) else {
                result(error("asset_unavailable", "照片已移除或无法获取原片")); return
            }
            _ = stateQueue.sync { pending.insert(requestID) }
            do {
                try FileManager.default.createDirectory(at: temporaryDirectory,
                                                       withIntermediateDirectories: true)
            } catch {
                _ = stateQueue.sync { pending.remove(requestID) }
                result(self.error("photo_cache_failed", "无法建立安全临时目录")); return
            }
            let target = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".asset")
            let options = PHAssetResourceRequestOptions()
            // Never fetch originals from iCloud silently or over cellular.
            options.isNetworkAccessAllowed = false
            PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: options) { [weak self] writeError in
                guard let self else { try? FileManager.default.removeItem(at: target); return }
                let allowed = self.stateQueue.sync { self.pending.remove(requestID) != nil }
                guard allowed else {
                    try? FileManager.default.removeItem(at: target)
                    DispatchQueue.main.async { result(self.error("photo_cancelled", "用户暂停了备份")) }
                    return
                }
                if writeError != nil {
                    try? FileManager.default.removeItem(at: target)
                    DispatchQueue.main.async { result(self.error("photo_export_failed", "无法读取本机原片；iCloud 中尚未下载的照片请先在系统照片中下载")) }
                    return
                }
                let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0, size <= 32 * 1024 * 1024 * 1024 else {
                    try? FileManager.default.removeItem(at: target)
                    DispatchQueue.main.async { result(self.error("photo_size_invalid", "原片大小无效或超过 32 GiB")) }
                    return
                }
                DispatchQueue.main.async { result(["path": target.path, "size": size]) }
            }
        case "cancelPrepare":
            let args = call.arguments as? [String: Any] ?? [:]
            let requestID = args["requestId"] as? String ?? ""
            result(stateQueue.sync { pending.remove(requestID) != nil })
        case "release":
            let args = call.arguments as? [String: Any] ?? [:]
            guard let path = args["path"] as? String else { result(false); return }
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let dir = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard url.path.hasPrefix(dir), url.path.hasSuffix(".asset") else { result(false); return }
            do {
                try FileManager.default.removeItem(at: url)
                result(true)
            } catch {
                result(false)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
