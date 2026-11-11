import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VisionAIPipeline {
    static let maxAIResponseLineBytes = 256 * 1024
    static let maxBatchCount = 16
    private static let analysisMaxPixelSize = 1280

    static func runBatch(names: [String], ignoreThermal: Bool = false) -> Bool {
        _ = pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0)
        var allSucceeded = true
        for (index, name) in names.enumerated() {
            let descriptor = Int32(3 + index)
            let itemResponse: AIWorkerItemResponse = autoreleasepool {
                if !ignoreThermal && ProcessInfo.processInfo.thermalState == .critical {
                    return .throttled(index: index, reason: "mac_thermal_critical")
                }
                return analyzeDescriptor(fd: descriptor, index: index, name: name)
            }
            if itemResponse.status == "error" {
                allSucceeded = false
            }
            if !writeJSONLine(itemResponse) {
                return false
            }
        }
        return allSucceeded
    }

    private static func analyzeDescriptor(fd: Int32, index: Int, name: String) -> AIWorkerItemResponse {
        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0,
              fileInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileInfo.st_size > 0 else {
            return .error(index: index, message: "输入描述符不是可读取的普通文件")
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, flags & O_ACCMODE == O_RDONLY else {
            return .error(index: index, message: "输入描述符必须以只读方式打开")
        }
        guard let mediaType = MediaTypeInfo(name: name), mediaType.kind == "photo" else {
            return .unsupported(index: index)
        }
        guard let source = FDImageProvider.source(fd: fd, size: Int64(fileInfo.st_size)) else {
            return .error(index: index, message: "图像格式无效或文件数据已损坏")
        }
        guard let uti = CGImageSourceGetType(source) as String?,
              let actualType = UTType(uti),
              actualType.conforms(to: .image) else {
            return .unsupported(index: index)
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: analysisMaxPixelSize,
        ]
        guard let uprightImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary),
              uprightImage.width >= 8, uprightImage.height >= 8 else {
            return .error(index: index, message: "无法解码分析图像")
        }

        let textAndScene = VisionTextAndSceneAnalyzer.analyze(image: uprightImage)
        let faceAndQuality = VisionFaceAndQualityAnalyzer.analyze(image: uprightImage)
        return .ok(
            index: index,
            ocrText: textAndScene.ocrText,
            ocrTokens: textAndScene.ocrTokens,
            sceneTags: textAndScene.sceneTags,
            faces: faceAndQuality.faces,
            featurePrintF16: faceAndQuality.featurePrintF16,
            sharpness: faceAndQuality.sharpness,
            aesthetics: faceAndQuality.aesthetics,
            isUtility: faceAndQuality.isUtility
        )
    }

    static func writeJSONLine(_ response: AIWorkerItemResponse) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(response),
              data.count < maxAIResponseLineBytes else {
            return false
        }
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
}
