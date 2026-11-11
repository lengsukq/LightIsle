import Accelerate
import CoreGraphics
import Foundation
import ObjectiveC
import Vision

protocol FaceEmbeddingProvider {
    var modelVersion: String { get }
    func extractEmbeddings(for faces: [VNFaceObservation], in image: CGImage) -> [[Float]?]
}

/// Primary Apple Neural Face Recognizer (ANFRv4, 128-D L2-normalized Float32).
/// Every runtime selector is checked with `responds(to:)` and invoked through
/// ABI-exact `@convention(c)` IMP pointers so scalar returns never touch ARC.
struct NativeANFRFaceprintProvider: FaceEmbeddingProvider {
    let modelVersion = "apple-anfr-v4-128f"

    func extractEmbeddings(for faces: [VNFaceObservation], in image: CGImage) -> [[Float]?] {
        guard !faces.isEmpty,
              let reqClass = NSClassFromString("VNCreateFaceprintRequest") as? VNImageBasedRequest.Type else {
            return Array(repeating: nil, count: faces.count)
        }
        let setInputSel = NSSelectorFromString("setInputFaceObservations:")
        let request = reqClass.init()
        guard request.responds(to: setInputSel) else {
            return Array(repeating: nil, count: faces.count)
        }
        typealias SetFacesIMP = @convention(c) (AnyObject, Selector, NSArray) -> Void
        let setFaces = unsafeBitCast(request.method(for: setInputSel), to: SetFacesIMP.self)
        setFaces(request, setInputSel, faces as NSArray)

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let results = request.results as? [VNFaceObservation],
              results.count == faces.count else {
            return Array(repeating: nil, count: faces.count)
        }
        return results.map(Self.readNormalizedVector(from:))
    }

    private static func readNormalizedVector(from observation: VNFaceObservation) -> [Float]? {
        let obj = observation as AnyObject
        let faceprintSel = NSSelectorFromString("faceprint")
        guard obj.responds(to: faceprintSel) else { return nil }
        typealias ObjectGetterIMP = @convention(c) (AnyObject, Selector) -> AnyObject?
        let getFaceprint = unsafeBitCast(obj.method(for: faceprintSel), to: ObjectGetterIMP.self)
        guard let fp = getFaceprint(obj, faceprintSel) else { return nil }

        let dataSel = NSSelectorFromString("descriptorData")
        let countSel = NSSelectorFromString("VNEntityIdentificationModelPrintElementCount")
        let typeSel = NSSelectorFromString("VNEntityIdentificationModelPrintElementType")
        guard fp.responds(to: dataSel), fp.responds(to: countSel), fp.responds(to: typeSel) else {
            return nil
        }

        typealias UIntGetterIMP = @convention(c) (AnyObject, Selector) -> UInt
        let getCount = unsafeBitCast(fp.method(for: countSel), to: UIntGetterIMP.self)
        let getType = unsafeBitCast(fp.method(for: typeSel), to: UIntGetterIMP.self)
        let getData = unsafeBitCast(fp.method(for: dataSel), to: ObjectGetterIMP.self)

        let elementCount = Int(getCount(fp, countSel))
        let elementType = getType(fp, typeSel)
        guard elementType == UInt(VNElementType.float.rawValue),
              elementCount >= 64, elementCount <= 1024,
              let nsData = getData(fp, dataSel) as? Data,
              nsData.count == elementCount * MemoryLayout<Float>.size else {
            return nil
        }
        let rawFloats = nsData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return VisionFaceAndQualityAnalyzer.l2Normalize(rawFloats)
    }
}

/// Public Vision fallback using upright face crop + `VNGenerateImageFeaturePrintRequest` Rev 2.
struct LandmarkFeaturePrintFallbackProvider: FaceEmbeddingProvider {
    let modelVersion = "apple-fprint-v2-768f"

    func extractEmbeddings(for faces: [VNFaceObservation], in image: CGImage) -> [[Float]?] {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        return faces.map { face in
            let rect = VisionFaceAndQualityAnalyzer.expandedTopLeftPixelRect(
                visionBox: face.boundingBox, imageWidth: imgW, imageHeight: imgH, marginRatio: 0.18
            )
            guard rect.width >= 24, rect.height >= 24,
                  let cropped = image.cropping(to: rect) else { return nil }
            return VisionFaceAndQualityAnalyzer.computeImageFeaturePrint(image: cropped)
        }
    }
}

enum VisionFaceAndQualityAnalyzer {
    private static let maxFacesPerPhoto = 12
    private static let minFaceBoxSide: CGFloat = 0.035

    struct Result {
        let faces: [AIFaceDTO]
        let featurePrintF16: String?
        let sharpness: Float
        let aesthetics: Float?
        let isUtility: Bool?
    }

    static func analyze(image: CGImage) -> Result {
        let faces = detectFaces(in: image)
        let featurePrint = computeImageFeaturePrint(image: image)
        let featurePrintF16 = featurePrint.flatMap(FloatVectorCodec.encodeFloat16Base64)
        let sharpness = computeLaplacianSharpness(image: image)
        let (aesthetics, isUtility) = computeAestheticsIfAvailable(image: image)
        return Result(
            faces: faces,
            featurePrintF16: featurePrintF16,
            sharpness: sharpness,
            aesthetics: aesthetics,
            isUtility: isUtility
        )
    }

    private static func detectFaces(in image: CGImage) -> [AIFaceDTO] {
        let rectReq = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([rectReq])) != nil,
              let candidates = rectReq.results, !candidates.isEmpty else {
            return []
        }

        let filtered = candidates
            .filter { $0.boundingBox.width >= minFaceBoxSide && $0.boundingBox.height >= minFaceBoxSide }
            .sorted { ($0.boundingBox.width * $0.boundingBox.height) > ($1.boundingBox.width * $1.boundingBox.height) }
            .prefix(maxFacesPerPhoto)
        let selectedFaces = Array(filtered)
        guard !selectedFaces.isEmpty else { return [] }

        let qualityReq = VNDetectFaceCaptureQualityRequest()
        qualityReq.inputFaceObservations = selectedFaces
        let landmarksReq = VNDetectFaceLandmarksRequest()
        landmarksReq.inputFaceObservations = selectedFaces
        try? handler.perform([qualityReq, landmarksReq])

        let qualityByUUID = Dictionary(
            uniqueKeysWithValues: (qualityReq.results ?? []).compactMap { obs in
                obs.faceCaptureQuality.map { (obs.uuid, $0) }
            }
        )
        let landmarksByUUID = Dictionary(
            uniqueKeysWithValues: (landmarksReq.results ?? []).compactMap { obs in
                obs.landmarks.map { (obs.uuid, $0) }
            }
        )

        let primary = NativeANFRFaceprintProvider()
        var vectors = primary.extractEmbeddings(for: selectedFaces, in: image)
        var activeVersion = primary.modelVersion
        if !vectors.contains(where: { $0 != nil }) {
            let fallback = LandmarkFeaturePrintFallbackProvider()
            vectors = fallback.extractEmbeddings(for: selectedFaces, in: image)
            activeVersion = fallback.modelVersion
        }

        var output: [AIFaceDTO] = []
        output.reserveCapacity(selectedFaces.count)
        for (idx, face) in selectedFaces.enumerated() {
            guard let vector = vectors[idx],
                  let encoded = FloatVectorCodec.encodeFloat32Base64(vector) else { continue }
            let topBox = normalizedTopLeftBox(fromVisionBox: face.boundingBox)
            let quality = clamp01(qualityByUUID[face.uuid] ?? 0.5)
            let eyeOpenness = estimateEyeOpenness(landmarks: landmarksByUUID[face.uuid])
            output.append(AIFaceDTO(
                boxX: Float(topBox.origin.x),
                boxY: Float(topBox.origin.y),
                boxW: Float(topBox.size.width),
                boxH: Float(topBox.size.height),
                quality: quality,
                eyeOpenness: eyeOpenness,
                modelVersion: activeVersion,
                embedding: encoded
            ))
        }
        return output
    }

    static func computeImageFeaturePrint(image: CGImage) -> [Float]? {
        let req = VNGenerateImageFeaturePrintRequest()
        if #available(macOS 14.0, *) {
            req.revision = VNGenerateImageFeaturePrintRequestRevision2
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([req])) != nil,
              let obs = req.results?.first,
              obs.elementType == .float,
              obs.elementCount > 0,
              obs.data.count == obs.elementCount * MemoryLayout<Float>.size else {
            return nil
        }
        let floats = obs.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return l2Normalize(floats)
    }

    private static func computeAestheticsIfAvailable(image: CGImage) -> (Float?, Bool?) {
        if #available(macOS 15.0, *) {
            let req = VNCalculateImageAestheticsScoresRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            if (try? handler.perform([req])) != nil, let first = req.results?.first {
                return (first.overallScore, first.isUtility)
            }
        }
        return (nil, nil)
    }

    /// Computes normalized [0, 1] sharpness using Accelerate vDSP over a 256px
    /// grayscale downsample so blurry burst shots rank below crisp frames.
    static func computeLaplacianSharpness(image: CGImage) -> Float {
        let maxEdge = 256
        let srcW = image.width, srcH = image.height
        guard srcW >= 8, srcH >= 8 else { return 0 }
        let scale = min(1.0, Double(maxEdge) / Double(max(srcW, srcH)))
        let w = max(8, Int((Double(srcW) * scale).rounded()))
        let h = max(8, Int((Double(srcH) * scale).rounded()))

        var pixels = [UInt8](repeating: 0, count: w * h)
        let graySpace = CGColorSpaceCreateDeviceGray()
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base, width: w, height: h,
                      bitsPerComponent: 8, bytesPerRow: w, space: graySpace,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }

        var laplacian: [Float] = []
        laplacian.reserveCapacity((w - 2) * (h - 2))
        for y in 1..<(h - 1) {
            let row = y * w
            for x in 1..<(w - 1) {
                let idx = row + x
                let center = Float(pixels[idx]) * -4.0
                let neighbors = Float(Int(pixels[idx - 1]) + Int(pixels[idx + 1]) + Int(pixels[idx - w]) + Int(pixels[idx + w]))
                laplacian.append(center + neighbors)
            }
        }
        guard !laplacian.isEmpty else { return 0 }
        var meanSquare: Float = 0
        vDSP_measqv(laplacian, 1, &meanSquare, vDSP_Length(laplacian.count))
        guard meanSquare.isFinite, meanSquare > 0 else { return 0 }
        return clamp01(meanSquare / (meanSquare + 350.0))
    }

    static func l2Normalize(_ values: [Float]) -> [Float]? {
        guard !values.isEmpty else { return nil }
        var sumSquares: Float = 0
        vDSP_svesq(values, 1, &sumSquares, vDSP_Length(values.count))
        let norm = sqrt(sumSquares)
        guard norm.isFinite, norm > 1e-6 else { return nil }
        var divisor = norm
        var normalized = [Float](repeating: 0, count: values.count)
        vDSP_vsdiv(values, 1, &divisor, &normalized, 1, vDSP_Length(values.count))
        return normalized
    }

    private static func estimateEyeOpenness(landmarks: VNFaceLandmarks2D?) -> Float {
        guard let landmarks else { return 0.75 }
        let ratios = [landmarks.leftEye, landmarks.rightEye].compactMap(eyeAspectRatio(region:))
        guard !ratios.isEmpty else { return 0.75 }
        let avg = ratios.reduce(0, +) / Float(ratios.count)
        // Typical open eye EAR ~0.22-0.34, closed eye < 0.10.
        return clamp01((avg - 0.08) / 0.20)
    }

    private static func eyeAspectRatio(region: VNFaceLandmarkRegion2D?) -> Float? {
        guard let region, region.pointCount >= 4 else { return nil }
        let pts = region.normalizedPoints
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for pt in pts {
            minX = min(minX, pt.x); maxX = max(maxX, pt.x)
            minY = min(minY, pt.y); maxY = max(maxY, pt.y)
        }
        let width = maxX - minX
        guard width > 1e-3 else { return nil }
        return Float((maxY - minY) / width)
    }

    static func normalizedTopLeftBox(fromVisionBox box: CGRect) -> CGRect {
        let x = max(0, min(1, box.origin.x))
        let y = max(0, min(1, 1.0 - box.origin.y - box.size.height))
        let w = max(0, min(1.0 - x, box.size.width))
        let h = max(0, min(1.0 - y, box.size.height))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func expandedTopLeftPixelRect(
        visionBox: CGRect,
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        marginRatio: CGFloat
    ) -> CGRect {
        let top = normalizedTopLeftBox(fromVisionBox: visionBox)
        let dx = top.width * marginRatio
        let dy = top.height * marginRatio
        let minX = max(0, (top.minX - dx) * imageWidth)
        let minY = max(0, (top.minY - dy) * imageHeight)
        let maxX = min(imageWidth, (top.maxX + dx) * imageWidth)
        let maxY = min(imageHeight, (top.maxY + dy) * imageHeight)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY)).integral
    }

    private static func clamp01(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return max(0, min(1, value))
    }
}
