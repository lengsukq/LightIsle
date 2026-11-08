import AVFoundation
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct WorkerResponse: Encodable {
    let version = 1
    let status: String
    let kind: String?
    let mime: String?
    let container: String?
    let videoCodec: String?
    let audioCodec: String?
    let durationSeconds: Double?
    let width: Int?
    let height: Int?
    let orientation: Int?
    let capturedAt: String?
    // Capture metadata. (0,0) is treated as "no location": the EXIF GPS
    // origin sits in open ocean and no real photo is taken there by accident.
    let latitude: Double?
    let longitude: Double?
    let cameraMake: String?
    let cameraModel: String?
    let lensModel: String?
    let iso: Int?
    let fNumber: Double?
    let exposureSeconds: Double?
    let focalLength: Double?
    let error: String?

    init(
        status: String,
        kind: String?,
        mime: String?,
        container: String?,
        videoCodec: String?,
        audioCodec: String?,
        durationSeconds: Double?,
        width: Int?,
        height: Int?,
        orientation: Int?,
        capturedAt: String?,
        latitude: Double? = nil,
        longitude: Double? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        iso: Int? = nil,
        fNumber: Double? = nil,
        exposureSeconds: Double? = nil,
        focalLength: Double? = nil,
        error: String? = nil
    ) {
        self.status = status
        self.kind = kind
        self.mime = mime
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.orientation = orientation
        self.capturedAt = capturedAt
        self.latitude = latitude
        self.longitude = longitude
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.iso = iso
        self.fNumber = fNumber
        self.exposureSeconds = exposureSeconds
        self.focalLength = focalLength
        self.error = error
    }

    static func error(_ message: String, kind: String? = nil) -> WorkerResponse {
        WorkerResponse(
            status: "error", kind: kind, mime: nil, container: nil,
            videoCodec: nil, audioCodec: nil, durationSeconds: nil,
            width: nil, height: nil, orientation: nil, capturedAt: nil,
            error: String(message.prefix(256))
        )
    }

    static func unsupported(kind: String? = nil, mime: String? = nil, container: String? = nil) -> WorkerResponse {
        WorkerResponse(
            status: "unsupported", kind: kind, mime: mime, container: container,
            videoCodec: nil, audioCodec: nil, durationSeconds: nil,
            width: nil, height: nil, orientation: nil, capturedAt: nil,
            error: nil
        )
    }
}

struct WorkerOptions {
    let command: String
    let inputFD: Int32
    let name: String
    let outputPath: String?
    let maxPixel: Int

    init(arguments: [String]) throws {
        guard let command = arguments.first, command == "probe" || command == "poster" || command == "thumbnail" else {
            throw WorkerError.usage("命令必须是 probe、poster 或 thumbnail")
        }
        guard arguments.count >= 5, (arguments.count - 1).isMultiple(of: 2) else {
            throw WorkerError.usage("缺少必需参数")
        }
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), values[key] == nil else {
                throw WorkerError.usage("参数格式无效")
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard values["--input-fd"] == "3" else {
            throw WorkerError.usage("input-fd 必须是 3")
        }
        guard let name = values["--name"], !name.isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw WorkerError.usage("name 必须是文件名")
        }
        let allowed = Set(["--input-fd", "--name", "--output", "--max-pixel"])
        guard values.keys.allSatisfy(allowed.contains) else {
            throw WorkerError.usage("存在未知参数")
        }
        var maxPixel = 512
        if let raw = values["--max-pixel"] {
            guard let parsed = Int(raw), parsed == 512 || parsed == 2048 else {
                throw WorkerError.usage("max-pixel 只支持 512 或 2048")
            }
            maxPixel = parsed
        }
        if command != "thumbnail", values["--max-pixel"] != nil {
            throw WorkerError.usage("max-pixel 仅用于 thumbnail")
        }
        let output = values["--output"]
        if command == "poster" || command == "thumbnail" {
            guard let output, !output.isEmpty else {
                throw WorkerError.usage("媒体输出命令必须提供 output")
            }
            let ext = URL(fileURLWithPath: output).pathExtension.lowercased()
            guard ext == "jpg" || ext == "jpeg" else {
                throw WorkerError.usage("媒体输出必须是 JPG")
            }
        } else if output != nil {
            throw WorkerError.usage("probe 不接受 output")
        }
        self.command = command
        inputFD = 3
        self.name = name
        outputPath = output
        self.maxPixel = maxPixel
    }
}

enum WorkerError: Error {
    case usage(String)
    case input(String)
    case media(String)
    case output(String)

    var responseMessage: String {
        switch self {
        case let .usage(message), let .input(message), let .media(message), let .output(message):
            return message
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage, .input: return 2
        case .media, .output: return 1
        }
    }
}

struct MediaTypeInfo {
    let kind: String
    let fileExtension: String

    static let photoExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "gif", "webp", "bmp"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    init?(name: String) {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return nil }
        if Self.photoExtensions.contains(ext), type.conforms(to: .image) {
            kind = "photo"
            fileExtension = ext
            return
        }
        if Self.videoExtensions.contains(ext) {
            kind = "video"
            fileExtension = ext
            return
        }
        return nil
    }
}

struct DetectedVideoContainer {
    let name: String
    let mime: String
    let contentType: String
}

/// A random-access file provider that never changes the inherited descriptor's
/// offset. ImageIO requests only the metadata and image blocks it needs.
final class FDImageProvider {
    static func source(fd: Int32, size: Int64) -> CGImageSource? {
        let callback: CGDataProviderGetBytesAtPositionCallback = { info, buffer, position, count in
            guard let info, position >= 0 else { return 0 }
            let descriptor = Int32(truncatingIfNeeded: Int(bitPattern: info))
            var total = 0
            while total < count {
                let readCount = pread(descriptor, buffer.advanced(by: total), count - total, position + off_t(total))
                if readCount < 0, errno == EINTR { continue }
                if readCount <= 0 { break }
                total += readCount
            }
            return total
        }
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0,
            getBytePointer: nil,
            releaseBytePointer: nil,
            getBytesAtPosition: callback,
            releaseInfo: nil
        )
        guard let info = UnsafeMutableRawPointer(bitPattern: Int(fd)),
              let provider = withUnsafePointer(to: &callbacks, {
                  CGDataProvider(directInfo: info, size: off_t(size), callbacks: $0)
              }) else { return nil }
        return CGImageSourceCreateWithDataProvider(provider, nil)
    }
}

/// AVFoundation's file URL path `/dev/fd/N` fails to open on current macOS.
/// This delegate gives it a private virtual URL and answers byte ranges from
/// fd 3 using bounded pread requests, so AVFoundation can seek without copying
/// or materializing the movie file.
final class FDAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let descriptor: Int32
    private let fileSize: Int64
    private let contentType: String
    private let chunkSize = 256 * 1024

    init(descriptor: Int32, fileSize: Int64, contentType: String) {
        self.descriptor = descriptor
        self.fileSize = fileSize
        self.contentType = contentType
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !request.isCancelled else { return true }
        if let information = request.contentInformationRequest {
            information.contentType = contentType
            information.contentLength = fileSize
            information.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }

        let start = max(dataRequest.currentOffset, dataRequest.requestedOffset)
        guard start >= 0, start <= fileSize else {
            request.finishLoading(with: WorkerError.input("媒体读取位置无效"))
            return true
        }
        let remaining = fileSize - start
        let requestedLength = dataRequest.requestsAllDataToEndOfResource
            ? remaining
            : min(remaining, max(0, Int64(dataRequest.requestedLength)))
        let end = start + requestedLength
        var offset = start
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }

        while offset < end {
            guard !request.isCancelled else { return true }
            let count = Int(min(Int64(chunkSize), end - offset))
            var readCount = 0
            while readCount == 0 {
                let result = pread(descriptor, buffer, count, off_t(offset))
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    request.finishLoading(with: WorkerError.input("媒体数据读取失败"))
                    return true
                }
                readCount = result
            }
            dataRequest.respond(with: Data(bytes: buffer, count: readCount))
            offset += Int64(readCount)
        }
        request.finishLoading()
        return true
    }
}
