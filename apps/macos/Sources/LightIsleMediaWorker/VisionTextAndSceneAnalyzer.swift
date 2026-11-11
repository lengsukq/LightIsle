import CoreGraphics
import Foundation
import NaturalLanguage
import Vision

enum VisionTextAndSceneAnalyzer {
    private static let maxOCRTextUTF8Bytes = 8 * 1024
    private static let maxOCRTokens = 256
    private static let minOCRConfidence: Float = 0.28
    private static let minSceneConfidence: Float = 0.16
    private static let maxSceneTags = 12

    /// Bilingual anchor dictionary mapping Apple Vision's built-in 1,303 taxonomy
    /// identifiers to natural Chinese and English search terms used in home NAS libraries.
    private static let bilingualSceneTerms: [String: [String]] = [
        "sunset_sunrise": ["日落", "夕阳", "晚霞", "日出", "黄昏", "朝霞", "sunset", "sunrise", "dusk"],
        "beach": ["海边", "沙滩", "海滩", "海岸", "海岛", "beach", "seaside", "coast"],
        "ocean": ["大海", "海洋", "海边", "海水", "ocean", "sea"],
        "water": ["水", "水面", "水域", "海边", "湖边", "water"],
        "lake": ["湖", "湖泊", "湖边", "水库", "lake"],
        "river": ["河", "河流", "江边", "溪流", "river"],
        "waterfall": ["瀑布", "山水", "waterfall"],
        "mountain": ["山", "大山", "山脉", "雪山", "登山", "风景", "mountain", "peak"],
        "sky": ["天空", "蓝天", "晴空", "sky"],
        "cloud": ["云", "白云", "云朵", "云海", "cloud"],
        "night_sky": ["夜空", "星空", "夜晚", "夜景", "night", "star"],
        "night": ["夜景", "夜晚", "黑夜", "灯光", "night"],
        "snow": ["雪", "雪景", "下雪", "冬天", "冰", "snow", "winter"],
        "forest": ["森林", "树林", "林间", "大自然", "forest", "woods"],
        "tree": ["树", "树木", "绿植", "tree"],
        "flower": ["花", "鲜花", "花朵", "赏花", "植物", "flower", "blossom"],
        "grass": ["草地", "草坪", "绿地", "郊游", "grass", "lawn"],
        "cat": ["猫", "小猫", "猫咪", "喵星人", "宠物", "cat", "kitten", "pet"],
        "adult_cat": ["猫", "小猫", "猫咪", "宠物", "cat", "pet"],
        "dog": ["狗", "小狗", "狗狗", "汪星人", "宠物", "dog", "puppy", "pet"],
        "bird": ["鸟", "小鸟", "飞鸟", "bird"],
        "fish": ["鱼", "水族", "海洋生物", "fish"],
        "animal": ["动物", "宠物", "animal", "pet"],
        "baby": ["宝宝", "婴儿", "小孩", "小朋友", "儿童", "baby", "infant"],
        "child": ["孩子", "小孩", "儿童", "小朋友", "宝宝", "child", "kid"],
        "people": ["人", "人物", "合影", "家人", "朋友", "people", "group"],
        "person": ["人", "人像", "人物", "person", "portrait"],
        "portrait": ["人像", "写真", "特写", "自拍", "portrait", "selfie"],
        "wedding": ["婚礼", "结婚", "婚纱", "wedding"],
        "party": ["聚会", "派对", "庆祝", "生日", "party", "celebration"],
        "cake": ["蛋糕", "生日蛋糕", "甜点", "生日", "cake", "birthday"],
        "food": ["美食", "食物", "吃饭", "聚餐", "菜肴", "做饭", "food", "meal"],
        "seafood": ["海鲜", "美食", "食物", "seafood", "food"],
        "dessert": ["甜品", "甜点", "下午茶", "美食", "dessert"],
        "fruit": ["水果", "果盘", "fruit"],
        "drink": ["饮品", "饮料", "咖啡", "奶茶", "酒", "drink", "beverage"],
        "coffee": ["咖啡", "拿铁", "下午茶", "coffee"],
        "car": ["车", "汽车", "轿车", "自驾", "car", "vehicle", "auto"],
        "bicycle": ["自行车", "单车", "骑行", "bicycle", "bike"],
        "train": ["火车", "高铁", "地铁", "列车", "train", "subway"],
        "airplane": ["飞机", "航班", "机场", "旅行", "airplane", "flight"],
        "boat": ["船", "游船", "帆船", "海边", "boat", "ship"],
        "building": ["建筑", "大楼", "房子", "城市", "building", "architecture"],
        "bridge": ["桥", "大桥", "桥梁", "bridge"],
        "street": ["街道", "马路", "街景", "城市", "street", "city"],
        "indoor": ["室内", "家里", "房间", "indoor", "room"],
        "outdoor": ["户外", "室外", "风景", "旅行", "outdoor"],
        "document": ["文档", "文件", "合同", "资料", "纸张", "证件", "扫描件", "document", "contract"],
        "receipt": ["发票", "收据", "小票", "账单", "报销", "receipt", "invoice", "bill"],
        "screenshot": ["截图", "屏幕截图", "手机截图", "screenshot"],
        "text": ["文字", "文本", "文档", "笔记", "text"],
        "printed_page": ["合同", "文档", "书页", "资料", "发票", "document", "page"],
        "handwriting": ["手写", "笔记", "字迹", "handwriting", "note"],
        "book": ["书", "书籍", "阅读", "book"],
        "qr_code": ["二维码", "扫码", "收款码", "qrcode"],
    ]

    struct Result {
        let ocrText: String?
        let ocrTokens: [String]
        let sceneTags: [AISceneTagDTO]
    }

    static func analyze(image: CGImage) -> Result {
        let ocrRequest = VNRecognizeTextRequest()
        ocrRequest.recognitionLevel = .accurate
        ocrRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        ocrRequest.usesLanguageCorrection = true

        let classifyRequest = VNClassifyImageRequest()
        if #available(macOS 14.0, *) {
            classifyRequest.revision = VNClassifyImageRequestRevision2
        }

        let animalRequest = VNRecognizeAnimalsRequest()

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        // Execute independent Vision requests resiliently so one unsupported
        // model revision in a VM never discards OCR results.
        try? handler.perform([ocrRequest])
        try? handler.perform([classifyRequest, animalRequest])

        let ocrText = extractOCRText(from: ocrRequest.results ?? [])
        let ocrTokens = ocrText.map(tokenizeNaturalLanguage) ?? []
        let sceneTags = extractSceneTags(
            classifications: classifyRequest.results ?? [],
            animals: animalRequest.results ?? []
        )
        return Result(ocrText: ocrText, ocrTokens: ocrTokens, sceneTags: sceneTags)
    }

    private static func extractOCRText(from observations: [VNRecognizedTextObservation]) -> String? {
        guard !observations.isEmpty else { return nil }
        var lines: [String] = []
        var usedBytes = 0
        for observation in observations {
            guard let top = observation.topCandidates(1).first,
                  top.confidence >= minOCRConfidence else { continue }
            let trimmed = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lineBytes = trimmed.utf8.count + 1
            if usedBytes + lineBytes > maxOCRTextUTF8Bytes {
                break
            }
            lines.append(trimmed)
            usedBytes += lineBytes
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// Uses macOS NaturalLanguage `NLTokenizer` for native Chinese/English word
    /// segmentation plus CJK 2-gram sliding tokens for substring recall.
    static func tokenizeNaturalLanguage(_ rawText: String) -> [String] {
        let normalized = rawText.precomposedStringWithCompatibilityMapping.lowercased()
        guard !normalized.isEmpty else { return [] }

        var seen = Set<String>()
        var ordered: [String] = []
        func appendToken(_ candidate: String) {
            guard ordered.count < maxOCRTokens else { return }
            let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
            guard cleaned.count >= 2 || cleaned.unicodeScalars.contains(where: isCJKScalar) else { return }
            guard cleaned.count <= 48, seen.insert(cleaned).inserted else { return }
            ordered.append(cleaned)
        }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            appendToken(String(normalized[range]))
            return ordered.count < maxOCRTokens
        }

        // Emit CJK 2-character bigrams so compound terms ("增值税", "专用发票", "身份证")
        // match regardless of word boundary granularity.
        var cjkRun: [Character] = []
        func flushCJKRun() {
            defer { cjkRun.removeAll(keepingCapacity: true) }
            guard cjkRun.count >= 2 else { return }
            for idx in 0..<(cjkRun.count - 1) where ordered.count < maxOCRTokens {
                appendToken(String([cjkRun[idx], cjkRun[idx + 1]]))
            }
        }
        for ch in normalized {
            if ch.unicodeScalars.allSatisfy(isCJKScalar) {
                cjkRun.append(ch)
            } else {
                flushCJKRun()
            }
        }
        flushCJKRun()
        return ordered
    }

    private static func extractSceneTags(
        classifications: [VNClassificationObservation],
        animals: [VNRecognizedObjectObservation]
    ) -> [AISceneTagDTO] {
        var merged: [String: Float] = [:]
        for item in classifications where item.confidence >= minSceneConfidence {
            let key = item.identifier.lowercased()
            merged[key] = max(merged[key] ?? 0, item.confidence)
        }
        for animal in animals {
            for label in animal.labels where label.confidence >= minSceneConfidence {
                let key = label.identifier.lowercased()
                merged[key] = max(merged[key] ?? 0, label.confidence)
            }
        }
        let sorted = merged.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }.prefix(maxSceneTags)

        let zhEmbedding = NLEmbedding.wordEmbedding(for: .simplifiedChinese)
        return sorted.map { label, confidence in
            let terms = buildSearchTerms(for: label, zhEmbedding: zhEmbedding)
            return AISceneTagDTO(label: label, confidence: confidence, searchTerms: terms)
        }
    }

    private static func buildSearchTerms(for label: String, zhEmbedding: NLEmbedding?) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        func add(_ raw: String) {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !token.isEmpty, token.count <= 32, seen.insert(token).inserted else { return }
            terms.append(token)
        }

        add(label)
        for part in label.split(separator: "_") where part.count >= 2 {
            add(String(part))
        }
        if let mapped = bilingualSceneTerms[label] {
            for anchor in mapped {
                add(anchor)
            }
            // Enrich primary Chinese anchor with closest macOS NLEmbedding synonym.
            if let primaryZh = mapped.first(where: { $0.unicodeScalars.contains(where: isCJKScalar) }),
               let zhEmbedding {
                for (neighbor, distance) in zhEmbedding.neighbors(for: primaryZh, maximumCount: 2) where distance < 0.86 {
                    add(neighbor)
                }
            }
        }
        return terms
    }

    private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}
