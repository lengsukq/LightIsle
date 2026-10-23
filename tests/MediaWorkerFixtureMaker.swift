import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
private struct MediaWorkerFixtureMaker {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else {
            throw FixtureError.invalidArguments
        }
        let destination = URL(fileURLWithPath: arguments[1])
        switch arguments[0] {
        case "heic":
            try makeHEIC(at: destination)
        case "mp4":
            try makeMP4(at: destination)
        default:
            throw FixtureError.invalidArguments
        }
    }

    private static func makeHEIC(at url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 80,
            height: 48,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw FixtureError.imageCreationFailed
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw FixtureError.heicUnavailable
        }
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05",
            kCGImagePropertyExifOffsetTimeOriginal: "+08:00",
        ]
        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFDateTime: "2020:01:02 03:04:05",
        ]
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.heicUnavailable
        }
    }

    private static func makeMP4(at url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 96,
                AVVideoHeightKey: 64,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 400_000,
                    AVVideoExpectedSourceFrameRateKey: 10,
                    AVVideoMaxKeyFrameIntervalKey: 10,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw FixtureError.videoWriterUnavailable }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 96,
                kCVPixelBufferHeightKey as String: 64,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )
        guard writer.startWriting() else { throw writer.error ?? FixtureError.videoWriterUnavailable }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<20 {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                96,
                64,
                kCVPixelFormatType_32ARGB,
                [
                    kCVPixelBufferCGImageCompatibilityKey: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                ] as CFDictionary,
                &buffer
            )
            guard status == kCVReturnSuccess, let buffer else {
                throw FixtureError.videoWriterUnavailable
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
                memset(baseAddress, 0x55, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else {
                throw writer.error ?? FixtureError.videoWriterUnavailable
            }
        }

        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 20) == .success, writer.status == .completed else {
            throw writer.error ?? FixtureError.videoWriterUnavailable
        }
    }
}

private enum FixtureError: Error {
    case invalidArguments
    case imageCreationFailed
    case heicUnavailable
    case videoWriterUnavailable
}
