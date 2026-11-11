import Foundation

struct AISceneTagDTO: Encodable, Sendable {
    let label: String
    let confidence: Float
    let searchTerms: [String]
}

struct AIFaceDTO: Encodable, Sendable {
    let boxX: Float
    let boxY: Float
    let boxW: Float
    let boxH: Float
    let quality: Float
    let eyeOpenness: Float
    let modelVersion: String
    let embedding: String
}

struct AIWorkerItemResponse: Encodable, Sendable {
    let version = 1
    let index: Int
    let status: String
    let ocrText: String?
    let ocrTokens: [String]?
    let sceneTags: [AISceneTagDTO]?
    let faces: [AIFaceDTO]?
    let featurePrintF16: String?
    let sharpness: Float?
    let aesthetics: Float?
    let isUtility: Bool?
    let error: String?

    static func ok(
        index: Int,
        ocrText: String?,
        ocrTokens: [String],
        sceneTags: [AISceneTagDTO],
        faces: [AIFaceDTO],
        featurePrintF16: String?,
        sharpness: Float,
        aesthetics: Float?,
        isUtility: Bool?
    ) -> AIWorkerItemResponse {
        AIWorkerItemResponse(
            index: index,
            status: "ok",
            ocrText: ocrText?.isEmpty == false ? ocrText : nil,
            ocrTokens: ocrTokens.isEmpty ? nil : ocrTokens,
            sceneTags: sceneTags.isEmpty ? nil : sceneTags,
            faces: faces.isEmpty ? nil : faces,
            featurePrintF16: featurePrintF16,
            sharpness: sharpness,
            aesthetics: aesthetics,
            isUtility: isUtility,
            error: nil
        )
    }

    static func unsupported(index: Int) -> AIWorkerItemResponse {
        AIWorkerItemResponse(
            index: index, status: "unsupported",
            ocrText: nil, ocrTokens: nil, sceneTags: nil, faces: nil,
            featurePrintF16: nil, sharpness: nil, aesthetics: nil, isUtility: nil, error: nil
        )
    }

    static func throttled(index: Int, reason: String) -> AIWorkerItemResponse {
        AIWorkerItemResponse(
            index: index, status: "throttled",
            ocrText: nil, ocrTokens: nil, sceneTags: nil, faces: nil,
            featurePrintF16: nil, sharpness: nil, aesthetics: nil, isUtility: nil,
            error: String(reason.prefix(128))
        )
    }

    static func error(index: Int, message: String) -> AIWorkerItemResponse {
        AIWorkerItemResponse(
            index: index, status: "error",
            ocrText: nil, ocrTokens: nil, sceneTags: nil, faces: nil,
            featurePrintF16: nil, sharpness: nil, aesthetics: nil, isUtility: nil,
            error: String(message.prefix(256))
        )
    }
}

enum FloatVectorCodec {
    /// Packs Float32 values into little-endian IEEE-754 Float16 bytes using
    /// Apple Silicon hardware conversion, halving SQLite storage footprint.
    static func encodeFloat16Base64(_ values: [Float]) -> String? {
        guard !values.isEmpty else { return nil }
        var raw = Data(capacity: values.count * MemoryLayout<UInt16>.size)
        for value in values {
            let finite = value.isFinite ? value : 0
            var bits = Float16(finite).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { raw.append(contentsOf: $0) }
        }
        return raw.base64EncodedString()
    }

    /// Encodes L2-normalized Float32 values as little-endian bytes in Base64.
    static func encodeFloat32Base64(_ values: [Float]) -> String? {
        guard !values.isEmpty else { return nil }
        var raw = Data(capacity: values.count * MemoryLayout<UInt32>.size)
        for value in values {
            let finite = value.isFinite ? value : 0
            var bits = finite.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { raw.append(contentsOf: $0) }
        }
        return raw.base64EncodedString()
    }
}
