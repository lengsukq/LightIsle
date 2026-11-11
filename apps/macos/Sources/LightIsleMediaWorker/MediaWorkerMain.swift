import AVFoundation
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaWorker {
    private static let maxJPEGOutputBytes = 8 * 1024 * 1024

    static func run(_ options: WorkerOptions) async throws -> WorkerResponse {
        guard let type = MediaTypeInfo(name: options.name) else {
            return .unsupported()
        }

        var fileInfo = stat()
        guard fstat(options.inputFD, &fileInfo) == 0,
              fileInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileInfo.st_size > 0 else {
            throw WorkerError.input("输入描述符不是可读取的普通文件")
        }
        let flags = fcntl(options.inputFD, F_GETFL)
        guard flags >= 0, flags & O_ACCMODE == O_RDONLY else {
            throw WorkerError.input("输入描述符必须以只读方式打开")
        }
        if options.command == "poster", type.kind != "video" {
            throw WorkerError.usage("poster 仅支持视频")
        }
        if options.command == "thumbnail", type.kind != "photo" {
            return .unsupported(kind: type.kind)
        }

        if type.kind == "photo" {
            guard let source = FDImageProvider.source(fd: options.inputFD, size: Int64(fileInfo.st_size)) else {
                throw WorkerError.media("图像格式无效或文件数据已损坏")
            }
            let metadata = try probePhoto(source: source, type: type)
            if options.command == "thumbnail" {
                guard let outputPath = options.outputPath else { throw WorkerError.usage("thumbnail 必须提供 output") }
                if metadata.status == "ok" {
                    try writePhotoThumbnail(source: source, outputPath: outputPath, maxPixel: options.maxPixel)
                }
            }
            return metadata
        }
        guard type.kind == "video" else { return .unsupported(kind: type.kind) }
        guard let container = try detectVideoContainer(fd: options.inputFD, size: Int64(fileInfo.st_size)) else {
            return .unsupported(kind: "video", container: "unknown")
        }

        let loader = FDAssetResourceLoader(
            descriptor: options.inputFD,
            fileSize: Int64(fileInfo.st_size),
            contentType: container.contentType
        )
        let assetURL = URL(string: "lightisle-fd://worker/input.\(type.fileExtension)")!
        let asset = AVURLAsset(url: assetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "lightisle-media-fd-loader"))

        let response = try await probeVideo(asset: asset, type: type, container: container)
        if options.command == "poster" {
            guard let outputPath = options.outputPath else { throw WorkerError.usage("poster 必须提供 output") }
            try await writePoster(asset: asset, duration: response.durationSeconds ?? 0, outputPath: outputPath)
        }
        return response
    }

    private static func probePhoto(source: CGImageSource, type: MediaTypeInfo) throws -> WorkerResponse {
        let copyOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, copyOptions as CFDictionary) as? [CFString: Any],
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw WorkerError.media("图像格式无效或文件数据已损坏")
        }
        guard let typeIdentifier = CGImageSourceGetType(source) as String?,
              let actualType = UTType(typeIdentifier), actualType.conforms(to: .image) else {
            return .unsupported(kind: type.kind, container: "unknown")
        }
        guard let width = integer(properties[kCGImagePropertyPixelWidth]),
              let height = integer(properties[kCGImagePropertyPixelHeight]),
              width > 0, height > 0 else {
            throw WorkerError.media("图像尺寸信息无效")
        }
        let orientation = integer(properties[kCGImagePropertyOrientation])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dateString = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? tiff?[kCGImagePropertyTIFFDateTime] as? String
        let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let location = gpsLocation(gps)
        let cameraMake = (tiff?[kCGImagePropertyTIFFMake] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cameraModel = (tiff?[kCGImagePropertyTIFFModel] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lensModel = (exif?[kCGImagePropertyExifLensModel] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isoRatings = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Any]
        let actualExtension = actualType.preferredFilenameExtension?.lowercased()
        let actualContainer: String
        switch actualExtension {
        case "jpg", "jpeg": actualContainer = "JPEG"
        case "tif", "tiff": actualContainer = "TIFF"
        case let value?: actualContainer = value.uppercased()
        case nil: actualContainer = actualType.identifier
        }
        return WorkerResponse(
            status: "ok", kind: type.kind, mime: actualType.preferredMIMEType, container: actualContainer,
            videoCodec: nil, audioCodec: nil, durationSeconds: nil,
            width: width, height: height, orientation: orientation,
            capturedAt: dateString.flatMap { formatEXIFDate($0, offset: offset) },
            latitude: location?.latitude, longitude: location?.longitude,
            cameraMake: cameraMake?.isEmpty == true ? nil : cameraMake,
            cameraModel: cameraModel?.isEmpty == true ? nil : cameraModel,
            lensModel: lensModel?.isEmpty == true ? nil : lensModel,
            iso: isoRatings?.compactMap(integer).first,
            fNumber: double(exif?[kCGImagePropertyExifFNumber]),
            exposureSeconds: double(exif?[kCGImagePropertyExifExposureTime]),
            focalLength: double(exif?[kCGImagePropertyExifFocalLength]),
            error: nil
        )
    }

    private static func writePhotoThumbnail(source: CGImageSource, outputPath: String, maxPixel: Int) throws {
        try autoreleasepool {
            guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
                throw WorkerError.media("图像格式无效或文件数据已损坏")
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  thumbnail.width > 0, thumbnail.height > 0,
                  thumbnail.width <= maxPixel, thumbnail.height <= maxPixel else {
                throw WorkerError.media("无法从照片生成缩略图")
            }
            let imageData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(imageData, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw WorkerError.output("无法创建 JPG 缩略图")
            }
            CGImageDestinationAddImage(
                destination,
                thumbnail,
                [kCGImageDestinationLossyCompressionQuality as String: 0.84] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else {
                throw WorkerError.output("无法编码 JPG 缩略图")
            }
            try writePrivateFile(Data(referencing: imageData), path: outputPath, maximumBytes: maxJPEGOutputBytes)
        }
    }

    private static func probeVideo(
        asset: AVURLAsset,
        type: MediaTypeInfo,
        container: DetectedVideoContainer
    ) async throws -> WorkerResponse {
        do {
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw WorkerError.media("视频轨道不存在")
            }
            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let transformedSize = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size
            let width = Int(abs(transformedSize.width).rounded())
            let height = Int(abs(transformedSize.height).rounded())
            guard width > 0, height > 0, width <= 100_000, height <= 100_000 else {
                throw WorkerError.media("视频尺寸信息无效")
            }
            let videoDescriptions = try await videoTrack.load(.formatDescriptions)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let audioDescriptions = try await audioTracks.asyncFirstFormatDescriptions()
            let seconds = CMTimeGetSeconds(duration)
            let durationSeconds = seconds.isFinite && seconds >= 0 ? seconds : nil
            let creationDate = try? await asset.load(.creationDate)
            let metadataItems = (try? await asset.load(.metadata)) ?? []
            // iPhones store location under the QuickTime mdta key, but ISO
            // writers (and our fixture maker) emit the standard uiso/loci
            // entry; accept either spelling.
            let quickTimeItem = AVMetadataItem.metadataItems(
                from: metadataItems,
                filteredByIdentifier: .quickTimeMetadataLocationISO6709
            ).first
            let isoItem = AVMetadataItem.metadataItems(
                from: metadataItems,
                withKey: "loci",
                keySpace: .isoUserData
            ).first
            var locationString: String?
            if let quickTimeItem {
                locationString = try? await quickTimeItem.load(.stringValue)
            }
            if locationString == nil, let isoItem {
                locationString = try? await isoItem.load(.stringValue)
            }
            let location = locationString.flatMap(parseISO6709Location)
            var capturedDate: Date?
            if let creationDate {
                capturedDate = try? await creationDate.load(.dateValue)
            }
            return WorkerResponse(
                status: "ok", kind: type.kind, mime: container.mime, container: container.name,
                videoCodec: videoDescriptions.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) },
                audioCodec: audioDescriptions.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) },
                durationSeconds: durationSeconds, width: width, height: height,
                orientation: nil,
                capturedAt: capturedDate.map(iso8601String),
                latitude: location?.latitude, longitude: location?.longitude,
                error: nil
            )
        } catch let error as WorkerError {
            throw error
        } catch {
            throw WorkerError.media("视频格式无法读取或文件数据已损坏")
        }
    }

    /// Reads at most 4 KiB from the inherited descriptor. The extension only
    /// selects the media family; the ftyp brands determine the reported format.
    private static func detectVideoContainer(fd: Int32, size: Int64) throws -> DetectedVideoContainer? {
        guard size >= 16 else { throw WorkerError.media("视频容器头无效") }
        let prefix = try readAt(fd: fd, offset: 0, count: Int(min(size, 32)))
        guard fourCC(prefix, at: 4) == "ftyp" else {
            throw WorkerError.media("视频容器头无效")
        }

        let size32 = readUInt32(prefix, at: 0)
        let headerSize: Int
        let boxSize: UInt64
        if size32 == 1 {
            guard prefix.count >= 24 else { throw WorkerError.media("视频容器头无效") }
            let extendedSize = readUInt64(prefix, at: 8)
            guard extendedSize <= UInt64(Int.max) else { throw WorkerError.media("视频容器头无效") }
            headerSize = 16
            boxSize = extendedSize
        } else {
            headerSize = 8
            boxSize = size32 == 0 ? UInt64(size) : UInt64(size32)
        }
        guard boxSize >= UInt64(headerSize + 8), boxSize <= UInt64(size) else {
            throw WorkerError.media("视频容器头无效")
        }

        let bytesToRead = Int(min(boxSize, 4096))
        let fileTypeBox = try readAt(fd: fd, offset: 0, count: bytesToRead)
        let majorBrand = fourCC(fileTypeBox, at: headerSize)
        var brands = [majorBrand]
        var brandOffset = headerSize + 8 // Skip major_brand and minor_version.
        while brandOffset + 4 <= fileTypeBox.count {
            brands.append(fourCC(fileTypeBox, at: brandOffset))
            brandOffset += 4
        }

        let mp4Brands: Set<String> = [
            "isom", "iso2", "iso3", "iso4", "iso5", "iso6", "mp41", "mp42",
            "avc1", "M4V ", "M4VH", "M4VP", "MSNV", "F4V ", "dash", "3gp4",
            "3gp5", "3gp6", "3gp7", "3g2a",
        ]
        let name: String
        let mime: String
        if majorBrand == "qt  " {
            name = "QuickTime"
            mime = "video/quicktime"
        } else if mp4Brands.contains(majorBrand) {
            name = "MPEG-4"
            mime = "video/mp4"
        } else if brands.dropFirst().contains("qt  ") {
            name = "QuickTime"
            mime = "video/quicktime"
        } else if brands.dropFirst().contains(where: mp4Brands.contains) {
            name = "MPEG-4"
            mime = "video/mp4"
        } else {
            return nil
        }
        let contentType = UTType(mimeType: mime)?.identifier ?? UTType.movie.identifier
        return DetectedVideoContainer(name: name, mime: mime, contentType: contentType)
    }

    private static func readAt(fd: Int32, offset: Int64, count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            let readCount = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return pread(fd, base.advanced(by: total), count - total, off_t(offset + Int64(total)))
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else { throw WorkerError.input("媒体头读取失败") }
            total += readCount
        }
        return bytes
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (UInt64(readUInt32(bytes, at: offset)) << 32)
            | UInt64(readUInt32(bytes, at: offset + 4))
    }

    private static func fourCC(_ bytes: [UInt8], at offset: Int) -> String {
        guard offset >= 0, offset + 4 <= bytes.count,
              let value = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) else {
            return ""
        }
        return value
    }

    private static func writePoster(asset: AVURLAsset, duration: Double, outputPath: String) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let requestedTime = CMTime(seconds: min(max(duration * 0.1, 0), 1), preferredTimescale: 600)
        let imageResult: (image: CGImage, actualTime: CMTime) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(image: CGImage, actualTime: CMTime), Error>) in
            generator.generateCGImageAsynchronously(for: requestedTime) { image, actualTime, error in
                if let image {
                    continuation.resume(returning: (image, actualTime))
                } else {
                    continuation.resume(throwing: error ?? WorkerError.media("无法从视频生成封面"))
                }
            }
        }

        try autoreleasepool {
            let imageData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(imageData, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw WorkerError.output("无法创建 JPG 封面")
            }
            CGImageDestinationAddImage(destination, imageResult.image, [kCGImageDestinationLossyCompressionQuality as String: 0.82] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw WorkerError.output("无法编码 JPG 封面")
            }
            try writePrivateFile(Data(referencing: imageData), path: outputPath, maximumBytes: maxJPEGOutputBytes)
        }
    }

    private static func writePrivateFile(_ data: Data, path: String, maximumBytes: Int) throws {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw WorkerError.output("JPG 输出超过大小限制")
        }
        let outputFD = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard outputFD >= 0 else { throw WorkerError.output("无法创建封面缓存文件") }
        var keepFile = false
        defer {
            close(outputFD)
            if !keepFile { unlink(path) }
        }
        guard fchmod(outputFD, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw WorkerError.output("无法设置 JPG 缩略图权限")
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw WorkerError.output("JPG 封面为空") }
            var offset = 0
            while offset < bytes.count {
                let written = write(outputFD, base.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw WorkerError.output("写入 JPG 封面失败") }
                offset += written
            }
        }
        guard fsync(outputFD) == 0 else { throw WorkerError.output("保存 JPG 封面失败") }
        keepFile = true
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? Double { return value }
        return nil
    }

    private struct Coordinate {
        let latitude: Double
        let longitude: Double
    }

    /// GPS dictionary coordinates are unsigned magnitudes; the reference
    /// hemisphere carries the sign. A missing reference keeps the stored sign.
    private static func gpsLocation(_ gps: [CFString: Any]?) -> Coordinate? {
        guard let gps,
              let rawLatitude = double(gps[kCGImagePropertyGPSLatitude]),
              let rawLongitude = double(gps[kCGImagePropertyGPSLongitude]) else { return nil }
        let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef] as? String
        let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
        let latitude: Double
        if latitudeRef == "S" { latitude = -abs(rawLatitude) }
        else if latitudeRef == "N" { latitude = abs(rawLatitude) }
        else { latitude = rawLatitude }
        let longitude: Double
        if longitudeRef == "W" { longitude = -abs(rawLongitude) }
        else if longitudeRef == "E" { longitude = abs(rawLongitude) }
        else { longitude = rawLongitude }
        guard abs(latitude) <= 90, abs(longitude) <= 180,
              latitude != 0 || longitude != 0 else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    /// QuickTime stores location as ISO 6709 text such as "+31.2311+121.4456/".
    private static func parseISO6709Location(_ value: String) -> Coordinate? {
        let pattern = "^([+-]\\d{1,2}(?:\\.\\d+)?)([+-]\\d{1,3}(?:\\.\\d+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let latitudeRange = Range(match.range(at: 1), in: value),
              let longitudeRange = Range(match.range(at: 2), in: value),
              let latitude = Double(value[latitudeRange]),
              let longitude = Double(value[longitudeRange]),
              abs(latitude) <= 90, abs(longitude) <= 180,
              latitude != 0 || longitude != 0 else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ]
        guard bytes.allSatisfy({ (32...126).contains($0) }),
              let text = String(bytes: bytes, encoding: .ascii) else {
            return String(format: "0x%08X", value)
        }
        return text
    }

    private static func formatEXIFDate(_ value: String, offset: String?) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.isLenient = false
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset, let timezone = timezone(offset) {
            parser.timeZone = timezone
        } else {
            parser.timeZone = TimeZone(secondsFromGMT: 0)
        }
        guard let date = parser.date(from: value) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func timezone(_ value: String) -> TimeZone? {
        guard value.count == 6, let signCharacter = value.first,
              signCharacter == "+" || signCharacter == "-",
              value[value.index(value.startIndex, offsetBy: 3)] == ":",
              let hours = Int(value[value.index(value.startIndex, offsetBy: 1)..<value.index(value.startIndex, offsetBy: 3)]),
              let minutes = Int(value.suffix(2)), hours <= 23, minutes <= 59 else { return nil }
        let sign = signCharacter == "+" ? 1 : -1
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }
}

private extension Array where Element == AVAssetTrack {
    func asyncFirstFormatDescriptions() async throws -> [CMFormatDescription] {
        for track in self {
            let descriptions = try await track.load(.formatDescriptions)
            if !descriptions.isEmpty { return descriptions }
        }
        return []
    }
}

private func writeResponse(_ response: WorkerResponse) -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard var data = try? encoder.encode(response), data.count < 32 * 1024 else { return false }
    data.append(0x0a)
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return -1 }
            return Darwin.write(STDOUT_FILENO, base.advanced(by: offset), bytes.count - offset)
        }
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { return false }
        offset += written
    }
    return true
}

@main
struct LightIsleMediaWorkerMain {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let parentPID = getppid()
        guard parentPID > 1 else { _exit(125) }
        let parentWatchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        parentWatchdog.schedule(deadline: .now() + .milliseconds(150), repeating: .milliseconds(150), leeway: .milliseconds(50))
        parentWatchdog.setEventHandler {
            if getppid() != parentPID { _exit(125) }
        }
        parentWatchdog.resume()
        defer { parentWatchdog.cancel() }

        do {
            let options = try WorkerOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.command == "ai-analyze" || options.command == "ai-batch" {
                let ok = VisionAIPipeline.runBatch(names: options.batchNames)
                Darwin.exit(ok ? 0 : 1)
            }
            let response = try await MediaWorker.run(options)
            _ = writeResponse(response)
            Darwin.exit(response.status == "error" ? 1 : 0)
        } catch let error as WorkerError {
            _ = writeResponse(.error(error.responseMessage))
            Darwin.exit(error.exitCode)
        } catch {
            _ = writeResponse(.error("媒体处理失败"))
            Darwin.exit(1)
        }
    }
}
