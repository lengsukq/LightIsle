import CryptoKit
import Flutter
import Foundation
import Network
import Photos

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
        IOSPhotoAlbums.encodeID(identifier)
    }

    private func localIdentifier(_ encoded: String) -> String? {
        IOSPhotoAlbums.decodeID(encoded)
    }

    private func assetGeneration(_ asset: PHAsset, _ resource: PHAssetResource) -> Int64 {
        IOSPhotoAlbums.assetGeneration(asset, resource)
    }

    private func isICloudNetworkRequired(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == PHPhotosErrorDomain && nsError.code == PHPhotosError.networkAccessRequired.rawValue {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == PHPhotosErrorDomain && underlying.code == PHPhotosError.networkAccessRequired.rawValue {
            return true
        }
        return false
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
        case "listAlbums":
            guard authorized() else {
                result(error("photo_permission_denied", "请授予全部照片读取权限，有限照片访问不适合完整备份。"))
                return
            }
            let args = call.arguments as? [String: Any] ?? [:]
            let includeVideos = args["includeVideos"] as? Bool ?? false
            DispatchQueue.global(qos: .userInitiated).async {
                let albums = IOSPhotoAlbums.listAlbums(includeVideos: includeVideos)
                DispatchQueue.main.async { result(["albums": albums]) }
            }
        case "inspectAssets":
            guard authorized() else {
                result(error("photo_permission_denied", "需要全部照片权限才能核验本机原片版本状态。"))
                return
            }
            let args = call.arguments as? [String: Any] ?? [:]
            let assetIds = (args["assetIds"] as? [Any] ?? []).compactMap { $0 as? String }
            DispatchQueue.global(qos: .userInitiated).async {
                let inspected = IOSPhotoAlbums.inspectAssets(encodedIds: assetIds)
                DispatchQueue.main.async { result(["assets": inspected]) }
            }
        case "requestDeleteAssets":
            guard authorized() else {
                result(error("photo_permission_denied", "需要全部照片权限才能发起系统安全释放确认。"))
                return
            }
            let args = call.arguments as? [String: Any] ?? [:]
            let assetIds = (args["assetIds"] as? [Any] ?? []).compactMap { $0 as? String }
            if assetIds.count > 500 {
                result(error("too_many_delete_assets", "单次最多释放 500 项原片，请分批操作。"))
                return
            }
            IOSPhotoAlbums.requestDeleteAssets(encodedIds: assetIds) { [weak self] outcome in
                DispatchQueue.main.async {
                    switch outcome {
                    case .success(let payload):
                        result(payload)
                    case .failure:
                        let err = self?.error("photo_delete_failed", "系统删除确认失败，本机照片未被删除。")
                            ?? FlutterError(code: "photo_delete_failed", message: "系统删除确认失败，本机照片未被删除。", details: nil)
                        result(err)
                    }
                }
            }
        case "list":
            guard authorized() else {
                result(error("photo_permission_denied", "请授予全部照片读取权限，有限照片访问不适合完整备份。"))
                return
            }
            let args = call.arguments as? [String: Any] ?? [:]
            let limit = min(100, max(1, args["limit"] as? Int ?? 40))
            let includeVideos = args["includeVideos"] as? Bool ?? false
            let albumScope = IOSPhotoAlbums.normalizeAlbumScope(args["albumScope"] as? String)
            let selectedAlbumIds = (args["selectedAlbumIds"] as? [Any] ?? []).compactMap { $0 as? String }
            let offsetString = args["beforeId"] as? String ?? ""
            guard offsetString.isEmpty || (offsetString.count <= 9 && offsetString.allSatisfy(\.isNumber)),
                  let offset = Int(offsetString.isEmpty ? "0" : offsetString), offset >= 0 else {
                result(error("invalid_cursor", "照片分页游标无效")); return
            }
            let assets = IOSPhotoAlbums.fetchAssets(
                includeVideos: includeVideos,
                albumScope: albumScope,
                collectionIds: selectedAlbumIds
            )
            guard offset <= assets.count else {
                result(error("photo_library_changed", "相册内容发生变化，请从最新照片重新扫描")); return
            }
            let end = min(offset + limit, assets.count)
            let pageSlice = end > offset ? Array(assets[offset..<end]) : []
            let albumNameMap = IOSPhotoAlbums.albumNames(for: pageSlice)
            var rows = [[String: Any]]()
            var invalidCount = 0
            for asset in pageSlice {
                let resources = PHAssetResource.assetResources(for: asset)
                let date = asset.modificationDate ?? asset.creationDate ?? .distantPast
                let albumName = albumNameMap[asset.localIdentifier] ?? "相机胶卷"
                var selected = [(String, PHAssetResource, Bool)]()
                if asset.mediaType == .image {
                    if let photo = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }) {
                        selected.append((assetID(asset.localIdentifier), photo, false))
                    } else {
                        invalidCount += 1
                    }
                    let rawTypes: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf", "pef"]
                    if let raw = resources.first(where: { item in
                        item.type == .alternatePhoto &&
                        rawTypes.contains((item.originalFilename as NSString).pathExtension.lowercased())
                    }) {
                        selected.append(("r." + assetID(asset.localIdentifier), raw, false))
                    }
                    if includeVideos && asset.mediaSubtypes.contains(.photoLive) {
                        if let paired = resources.first(where: { $0.type == .pairedVideo }) {
                            selected.append(("l." + assetID(asset.localIdentifier), paired, true))
                        } else {
                            invalidCount += 1
                        }
                    }
                } else if includeVideos && asset.mediaType == .video {
                    if let video = resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo }) {
                        selected.append(("v." + assetID(asset.localIdentifier), video, true))
                    } else {
                        invalidCount += 1
                    }
                }
                for (encoded, resource, isVideo) in selected {
                    rows.append([
                        "id": encoded,
                        "name": resource.originalFilename,
                        "modified": Int64(date.timeIntervalSince1970),
                        "size": 0,
                        "generation": assetGeneration(asset, resource),
                        "albumName": albumName,
                        "isVideo": isVideo,
                    ])
                }
            }
            result([
                "items": rows,
                "nextCursor": end < assets.count ? String(end) : "",
                "version": IOSPhotoAlbums.versionStamp(assets, albumScope: albumScope, collectionIds: selectedAlbumIds),
                "invalidCount": invalidCount,
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
            let allowICloud = (args["allowICloudDownload"] as? Bool == true) && stateQueue.sync { connectedToWifi }
            let kind: String
            let resourceID: String
            if encoded.hasPrefix("l.") {
                kind = "live"
                resourceID = String(encoded.dropFirst(2))
            } else if encoded.hasPrefix("v.") {
                kind = "video"
                resourceID = String(encoded.dropFirst(2))
            } else if encoded.hasPrefix("r.") {
                kind = "raw"
                resourceID = String(encoded.dropFirst(2))
            } else {
                kind = "photo"
                resourceID = encoded
            }
            guard (kind == "photo" || kind == "raw" || includeVideos),
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
                        case "raw": return asset.mediaType == .image &&
                            item.type == .alternatePhoto &&
                            ["dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf", "pef"]
                                .contains((item.originalFilename as NSString).pathExtension.lowercased())
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
            options.isNetworkAccessAllowed = allowICloud
            PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: options) { [weak self] writeError in
                guard let self else { try? FileManager.default.removeItem(at: target); return }
                let allowed = self.stateQueue.sync { self.pending.remove(requestID) != nil }
                guard allowed else {
                    try? FileManager.default.removeItem(at: target)
                    DispatchQueue.main.async { result(self.error("photo_cancelled", "用户暂停了备份")) }
                    return
                }
                if let writeError {
                    try? FileManager.default.removeItem(at: target)
                    if self.isICloudNetworkRequired(writeError) {
                        DispatchQueue.main.async {
                            result(self.error("icloud_download_required", "原片保存在 iCloud 云端，尚未下载到本机；可在设置中允许 Wi-Fi 下载或先在系统照片中下载。"))
                        }
                    } else {
                        DispatchQueue.main.async {
                            result(self.error("photo_export_failed", "无法读取本机原片；iCloud 中尚未下载的照片请先在系统照片中下载"))
                        }
                    }
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
