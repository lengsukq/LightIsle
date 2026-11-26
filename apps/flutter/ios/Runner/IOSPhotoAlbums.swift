import CryptoKit
import Foundation
import Photos

/// PhotoKit album discovery, collection-scoped asset fetching, primary album
/// lookup, and OS-confirmed asset deletion for LightIsle iOS photo backup.
enum IOSPhotoAlbums {
    static let scopeCamera = "camera"
    static let scopeAll = "all"
    static let scopeSelected = "selected"
    static let scopeExcluded = "excluded"

    private static let maxCollectionFilterCount = 200
    private static let defaultCameraAlbumName = "相机胶卷"
    private static let screenshotsAlbumName = "截屏"
    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf", "pef",
    ]

    /// Deterministic positive 52-bit version stamp that changes whenever an
    /// asset is edited, reverted, or its PHAssetResource metadata changes.
    static func assetGeneration(_ asset: PHAsset, _ resource: PHAssetResource) -> Int64 {
        let modMicros = Int64(((asset.modificationDate ?? asset.creationDate ?? .distantPast).timeIntervalSince1970 * 1_000_000.0).rounded())
        let createdMicros = Int64(((asset.creationDate ?? .distantPast).timeIntervalSince1970 * 1_000_000.0).rounded())
        let raw = "\(asset.localIdentifier)|\(modMicros)|\(createdMicros)|\(asset.pixelWidth)x\(asset.pixelHeight)|\(asset.mediaSubtypes.rawValue)|\(resource.type.rawValue)|\(resource.originalFilename)|\(resource.uniformTypeIdentifier)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        var value: UInt64 = 0
        for byte in digest.prefix(7) {
            value = (value << 8) | UInt64(byte)
        }
        let bounded = Int64(value & 0x000F_FFFF_FFFF_FFFF)
        return bounded > 0 ? bounded : 1
    }

    private static let smartAlbumDefinitions: [(PHAssetCollectionSubtype, String, Bool)] = [
        (.smartAlbumUserLibrary, "最近项目", true),
        (.smartAlbumFavorites, "个人收藏", false),
        (.smartAlbumVideos, "视频", false),
        (.smartAlbumSelfPortraits, "自拍", true),
        (.smartAlbumLivePhotos, "实况照片", true),
        (.smartAlbumScreenshots, "截屏", false),
    ]

    static func normalizeAlbumScope(_ raw: String?) -> String {
        switch raw {
        case scopeCamera: return scopeCamera
        case scopeSelected: return scopeSelected
        case scopeExcluded: return scopeExcluded
        default: return scopeAll
        }
    }

    static func encodeID(_ identifier: String) -> String {
        Data(identifier.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeID(_ encoded: String) -> String? {
        guard encoded.count <= 200,
              encoded.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            return nil
        }
        var value = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty,
              decoded.count < 150 else {
            return nil
        }
        return decoded
    }

    static func decodeCollectionIdentifiers(_ encodedIds: [String]) -> [String] {
        var seen = Set<String>()
        var identifiers = [String]()
        for raw in encodedIds {
            if identifiers.count >= maxCollectionFilterCount { break }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let decoded = decodeID(trimmed),
                  seen.insert(decoded).inserted else {
                continue
            }
            identifiers.append(decoded)
        }
        return identifiers.sorted()
    }

    static func collectionSignature(_ encodedIds: [String]) -> String {
        let normalized = decodeCollectionIdentifiers(encodedIds)
        if normalized.isEmpty { return "none" }
        let digest = SHA256.hash(data: Data(normalized.joined(separator: "\n").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func mediaPredicate(includeVideos: Bool, excludeScreenshots: Bool = false) -> NSPredicate {
        let screenshotBit = PHAssetMediaSubtype.photoScreenshot.rawValue
        if includeVideos {
            if excludeScreenshots {
                return NSPredicate(
                    format: "(mediaType == %d || mediaType == %d) && ((mediaSubtypes & %d) == 0)",
                    PHAssetMediaType.image.rawValue,
                    PHAssetMediaType.video.rawValue,
                    screenshotBit
                )
            }
            return NSPredicate(
                format: "mediaType == %d || mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
        }
        if excludeScreenshots {
            return NSPredicate(
                format: "mediaType == %d && ((mediaSubtypes & %d) == 0)",
                PHAssetMediaType.image.rawValue,
                screenshotBit
            )
        }
        return NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    }

    private static func sortedFetchOptions(includeVideos: Bool, excludeScreenshots: Bool = false) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = mediaPredicate(includeVideos: includeVideos, excludeScreenshots: excludeScreenshots)
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false),
            NSSortDescriptor(key: "localIdentifier", ascending: false),
        ]
        return options
    }

    static func listAlbums(includeVideos: Bool) -> [[String: Any]] {
        let countOptions = PHFetchOptions()
        countOptions.predicate = mediaPredicate(includeVideos: includeVideos)

        var seen = Set<String>()
        var smartRows = [[String: Any]]()
        for (subtype, fallbackName, isCamera) in smartAlbumDefinitions {
            if subtype == .smartAlbumVideos && !includeVideos { continue }
            let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
            collections.enumerateObjects { collection, _, _ in
                guard seen.insert(collection.localIdentifier).inserted else { return }
                let assets = PHAsset.fetchAssets(in: collection, options: countOptions)
                guard assets.count > 0 else { return }
                let title = (collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? fallbackName
                smartRows.append([
                    "id": encodeID(collection.localIdentifier),
                    "name": title,
                    "kind": "smart",
                    "count": assets.count,
                    "totalBytes": 0,
                    "relativePath": "",
                    "coverAssetId": assets.firstObject.map { encodeID($0.localIdentifier) } ?? "",
                    "isCamera": isCamera,
                ])
            }
        }

        var userRows = [[String: Any]]()
        let userCollections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        userCollections.enumerateObjects { collection, _, _ in
            guard seen.insert(collection.localIdentifier).inserted else { return }
            let assets = PHAsset.fetchAssets(in: collection, options: countOptions)
            guard assets.count > 0 else { return }
            let title = (collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "未命名相簿"
            userRows.append([
                "id": encodeID(collection.localIdentifier),
                "name": title,
                "kind": "user",
                "count": assets.count,
                "totalBytes": 0,
                "relativePath": "",
                "coverAssetId": assets.firstObject.map { encodeID($0.localIdentifier) } ?? "",
                "isCamera": false,
            ])
        }
        userRows.sort { ($0["count"] as? Int ?? 0) > ($1["count"] as? Int ?? 0) }
        return smartRows + userRows
    }

    static func fetchAssets(
        includeVideos: Bool,
        albumScope: String,
        collectionIds: [String]
    ) -> [PHAsset] {
        let scope = normalizeAlbumScope(albumScope)
        switch scope {
        case scopeCamera:
            let result = PHAsset.fetchAssets(with: sortedFetchOptions(includeVideos: includeVideos, excludeScreenshots: true))
            return toArray(result)
        case scopeAll:
            let result = PHAsset.fetchAssets(with: sortedFetchOptions(includeVideos: includeVideos))
            return toArray(result)
        case scopeSelected:
            let identifiers = decodeCollectionIdentifiers(collectionIds)
            if identifiers.isEmpty { return [] }
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: identifiers, options: nil)
            let options = PHFetchOptions()
            options.predicate = mediaPredicate(includeVideos: includeVideos)
            var byId = [String: PHAsset]()
            collections.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: options)
                assets.enumerateObjects { asset, _, _ in
                    byId[asset.localIdentifier] = asset
                }
            }
            return sortDeterministically(Array(byId.values))
        case scopeExcluded:
            let all = toArray(PHAsset.fetchAssets(with: sortedFetchOptions(includeVideos: includeVideos)))
            let identifiers = decodeCollectionIdentifiers(collectionIds)
            if identifiers.isEmpty { return all }
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: identifiers, options: nil)
            let options = PHFetchOptions()
            options.predicate = mediaPredicate(includeVideos: includeVideos)
            var excludedIds = Set<String>()
            collections.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: options)
                assets.enumerateObjects { asset, _, _ in
                    excludedIds.insert(asset.localIdentifier)
                }
            }
            return all.filter { !excludedIds.contains($0.localIdentifier) }
        default:
            return toArray(PHAsset.fetchAssets(with: sortedFetchOptions(includeVideos: includeVideos)))
        }
    }

    /// Maps each asset in the current page to its first user album name,
    /// falling back to "截屏" or "相机胶卷" when not inside any user album.
    static func albumNames(for pageAssets: [PHAsset]) -> [String: String] {
        if pageAssets.isEmpty { return [:] }
        var remaining = Set(pageAssets.map(\.localIdentifier))
        var names = [String: String]()
        let userCollections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        userCollections.enumerateObjects { collection, _, stop in
            if remaining.isEmpty {
                stop.pointee = true
                return
            }
            guard let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                return
            }
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "localIdentifier IN %@", Array(remaining))
            let matched = PHAsset.fetchAssets(in: collection, options: options)
            matched.enumerateObjects { asset, _, _ in
                if names[asset.localIdentifier] == nil {
                    names[asset.localIdentifier] = title
                    remaining.remove(asset.localIdentifier)
                }
            }
        }
        for asset in pageAssets where names[asset.localIdentifier] == nil {
            if asset.mediaSubtypes.contains(.photoScreenshot) {
                names[asset.localIdentifier] = screenshotsAlbumName
            } else {
                names[asset.localIdentifier] = defaultCameraAlbumName
            }
        }
        return names
    }

    static func versionStamp(
        _ assets: [PHAsset],
        albumScope: String,
        collectionIds: [String]
    ) -> String {
        let first = assets.first
        let last = assets.last
        let firstTime = first?.modificationDate?.timeIntervalSince1970 ?? 0
        let lastTime = last?.modificationDate?.timeIntervalSince1970 ?? 0
        let sig = collectionSignature(collectionIds)
        return "ios:\(albumScope):\(sig):\(assets.count):\(first?.localIdentifier ?? ""):\(firstTime):\(last?.localIdentifier ?? ""):\(lastTime)"
    }

    static func decodeAssetIdentifiers(_ encodedIds: [String]) -> [String] {
        var seen = Set<String>()
        var identifiers = [String]()
        for raw in encodedIds {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let bare: String
            if trimmed.hasPrefix("l.") || trimmed.hasPrefix("v.") || trimmed.hasPrefix("r.") {
                bare = String(trimmed.dropFirst(2))
            } else {
                bare = trimmed
            }
            guard let decoded = decodeID(bare), seen.insert(decoded).inserted else {
                continue
            }
            identifiers.append(decoded)
        }
        return identifiers
    }

    static func inspectAssets(encodedIds: [String]) -> [String: [String: Any]] {
        let identifiers = decodeAssetIdentifiers(encodedIds)
        if identifiers.isEmpty { return [:] }

        var output = [String: [String: Any]]()
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        assets.enumerateObjects { asset, _, _ in
            let baseId = encodeID(asset.localIdentifier)
            let resources = PHAssetResource.assetResources(for: asset)
            let modDate = asset.modificationDate ?? asset.creationDate ?? .distantPast
            let modMs = Int64((modDate.timeIntervalSince1970 * 1000.0).rounded())

            let photoResource = asset.mediaType == .image
                ? resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto })
                : nil
            let rawResource = asset.mediaType == .image
                ? resources.first(where: { item in
                    item.type == .alternatePhoto &&
                        rawExtensions.contains((item.originalFilename as NSString).pathExtension.lowercased())
                })
                : nil
            let hasLiveVideo = asset.mediaType == .image && asset.mediaSubtypes.contains(.photoLive)
            let liveVideoResource = hasLiveVideo
                ? resources.first(where: { $0.type == .pairedVideo })
                : nil
            let videoResource = asset.mediaType == .video
                ? resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo })
                : nil

            var generations = [String: Int64]()
            var requiredAssetIds = [String]()
            if let photo = photoResource {
                generations[baseId] = assetGeneration(asset, photo)
                requiredAssetIds.append(baseId)
            }
            if let raw = rawResource {
                let rawId = "r." + baseId
                generations[rawId] = assetGeneration(asset, raw)
                requiredAssetIds.append(rawId)
            }
            if hasLiveVideo {
                let liveId = "l." + baseId
                requiredAssetIds.append(liveId)
                if let live = liveVideoResource {
                    generations[liveId] = assetGeneration(asset, live)
                }
            }
            if let video = videoResource {
                let videoId = "v." + baseId
                generations[videoId] = assetGeneration(asset, video)
                requiredAssetIds.append(videoId)
            }
            let primaryGeneration = generations[baseId] ?? generations["v." + baseId] ?? 0
            output[baseId] = [
                "exists": true,
                "modificationDate": modMs,
                "assetGeneration": primaryGeneration,
                "generations": generations,
                "hasPhoto": photoResource != nil,
                "hasRaw": rawResource != nil,
                "hasLiveVideo": hasLiveVideo,
                "hasVideo": videoResource != nil,
                "requiredAssetIds": requiredAssetIds,
            ]
        }

        for identifier in identifiers {
            let baseId = encodeID(identifier)
            if output[baseId] == nil {
                output[baseId] = [
                    "exists": false,
                    "modificationDate": 0,
                    "assetGeneration": 0,
                    "generations": [String: Int64](),
                    "hasPhoto": false,
                    "hasRaw": false,
                    "hasLiveVideo": false,
                    "hasVideo": false,
                    "requiredAssetIds": [String](),
                ]
            }
        }
        return output
    }

    static func requestDeleteAssets(
        encodedIds: [String],
        completion: @escaping (Result<[String: Any], NSError>) -> Void
    ) {
        let identifiers = decodeAssetIdentifiers(encodedIds)
        if identifiers.isEmpty {
            completion(.success([
                "deleted": true,
                "cancelled": false,
                "deletedCount": 0,
                "alreadyMissingCount": encodedIds.count,
                "deletedAssetIds": [String](),
            ]))
            return
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        if assets.count == 0 {
            completion(.success([
                "deleted": true,
                "cancelled": false,
                "deletedCount": 0,
                "alreadyMissingCount": identifiers.count,
                "deletedAssetIds": [String](),
            ]))
            return
        }
        var existingEncodedIds = [String]()
        existingEncodedIds.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            existingEncodedIds.append(encodeID(asset.localIdentifier))
        }
        let targetCount = assets.count
        let missingCount = max(0, identifiers.count - targetCount)
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { success, error in
            if success {
                completion(.success([
                    "deleted": true,
                    "cancelled": false,
                    "deletedCount": targetCount,
                    "alreadyMissingCount": missingCount,
                    "deletedAssetIds": existingEncodedIds,
                ]))
                return
            }
            if let nsError = error as NSError?,
               nsError.domain == PHPhotosErrorDomain,
               nsError.code == PHPhotosError.userCancelled.rawValue {
                completion(.success([
                    "deleted": false,
                    "cancelled": true,
                    "deletedCount": 0,
                    "alreadyMissingCount": missingCount,
                    "deletedAssetIds": [String](),
                ]))
                return
            }
            let failure = (error as NSError?) ?? NSError(
                domain: "LightIslePhotoDelete",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "系统未能完成相册原片删除，本机照片未被修改。"]
            )
            completion(.failure(failure))
        }
    }

    private static func toArray(_ result: PHFetchResult<PHAsset>) -> [PHAsset] {
        var list = [PHAsset]()
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        return list
    }

    private static func sortDeterministically(_ assets: [PHAsset]) -> [PHAsset] {
        assets.sorted { lhs, rhs in
            let leftDate = lhs.creationDate ?? .distantPast
            let rightDate = rhs.creationDate ?? .distantPast
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            return lhs.localIdentifier > rhs.localIdentifier
        }
    }
}
