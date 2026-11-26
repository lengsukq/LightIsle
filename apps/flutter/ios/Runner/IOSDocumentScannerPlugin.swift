import Flutter
import PhotosUI
import UIKit
import VisionKit

/// Native document scanner (`lightisle/document-scanner`) powered by Apple
/// VisionKit (`VNDocumentCameraViewController`) with zero third-party SDKs.
/// Falls back cleanly to `PHPickerViewController` (or system camera when
/// explicitly requested and authorized) on unsupported devices/simulators.
final class IOSDocumentScannerPlugin: NSObject {
    static let channelName = "lightisle/document-scanner"

    private let channel: FlutterMethodChannel
    private let scanDirectory: URL
    private var pendingResult: FlutterResult?
    private weak var activeController: UIViewController?

    private static let maxPages = 10
    private static let maxEdgePx: CGFloat = 2400
    private static let jpegQuality: CGFloat = 0.88
    private static let staleCacheAgeSeconds: TimeInterval = 24 * 60 * 60

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        scanDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightisle-doc-scans", isDirectory: true)
        super.init()
        cleanupOldScans()
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(FlutterError(code: "scanner_unavailable", message: "文档扫描服务已关闭。", details: nil))
                return
            }
            self.handle(call, result: result)
        }
    }

    func stop() {
        channel.setMethodCallHandler(nil)
        if let pending = pendingResult {
            pendingResult = nil
            pending(["cancelled": true, "paths": [String]()])
        }
        activeController = nil
    }

    private var hasCameraUsageDescription: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visionKitSupported: Bool {
        VNDocumentCameraViewController.isSupported && hasCameraUsageDescription
    }

    private var cameraSupported: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera) && hasCameraUsageDescription
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAvailable":
            result([
                "scanner": visionKitSupported,
                "camera": cameraSupported,
                "picker": true,
            ])
        case "scanDocument":
            let args = call.arguments as? [String: Any] ?? [:]
            let source = (args["source"] as? String ?? "scanner").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            startCapture(source: source, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startCapture(source: String, result: @escaping FlutterResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.pendingResult == nil else {
                result(FlutterError(code: "scanner_busy", message: "请先完成当前的票据扫描或图片选择。", details: nil))
                return
            }
            guard let presenter = self.topPresenter() else {
                result(FlutterError(code: "scanner_unavailable", message: "请在应用前台打开票据扫描。", details: nil))
                return
            }

            self.pendingResult = result

            if source == "scanner" && self.visionKitSupported {
                let scanner = VNDocumentCameraViewController()
                scanner.delegate = self
                self.activeController = scanner
                presenter.present(scanner, animated: true)
                return
            }

            if source == "camera" && self.cameraSupported {
                let picker = UIImagePickerController()
                picker.sourceType = .camera
                picker.delegate = self
                self.activeController = picker
                presenter.present(picker, animated: true)
                return
            }

            var config = PHPickerConfiguration(photoLibrary: .shared())
            config.filter = .images
            config.selectionLimit = Self.maxPages
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            self.activeController = picker
            presenter.present(picker, animated: true)
        }
    }

    private func topPresenter() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let window = scene.windows.first(where: { $0.isKeyWindow }),
            var presenter = window.rootViewController else {
            return nil
        }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        return presenter
    }

    private func finishSuccess(_ payload: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let result = self.pendingResult else { return }
            self.pendingResult = nil
            self.activeController = nil
            result(payload)
        }
    }

    private func finishError(code: String, message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let result = self.pendingResult else { return }
            self.pendingResult = nil
            self.activeController = nil
            result(FlutterError(code: code, message: message, details: nil))
        }
    }

    private func saveNormalizedJPEG(_ image: UIImage) -> String? {
        let normalized = normalizeImage(image)
        guard let data = normalized.jpegData(compressionQuality: Self.jpegQuality) else {
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: scanDirectory, withIntermediateDirectories: true)
            let name = "doc_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8)).jpg"
            let url = scanDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    private func normalizeImage(_ image: UIImage) -> UIImage {
        let originalSize = image.size
        guard originalSize.width > 0 && originalSize.height > 0 else { return image }
        let longest = max(originalSize.width, originalSize.height)
        let scaleFactor = longest > Self.maxEdgePx ? (Self.maxEdgePx / longest) : 1.0
        let targetSize = CGSize(
            width: (originalSize.width * scaleFactor).rounded(),
            height: (originalSize.height * scaleFactor).rounded()
        )
        if image.imageOrientation == .up && scaleFactor >= 0.999 {
            return image
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func cleanupOldScans() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: scanDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-Self.staleCacheAgeSeconds)
        for url in entries {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if mod < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

extension IOSDocumentScannerPlugin: VNDocumentCameraViewControllerDelegate {
    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true) { [weak self] in
            self?.finishSuccess(["cancelled": true, "paths": [String]()])
        }
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        controller.dismiss(animated: true) { [weak self] in
            self?.finishError(code: "capture_failed", message: "文档扫描未能完成，请重试或改用从相册选取。")
        }
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        let pageCount = min(scan.pageCount, Self.maxPages)
        var images = [UIImage]()
        images.reserveCapacity(pageCount)
        for idx in 0..<pageCount {
            images.append(scan.imageOfPage(at: idx))
        }
        controller.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let paths = images.compactMap { self.saveNormalizedJPEG($0) }
                if paths.isEmpty {
                    self.finishError(code: "capture_failed", message: "未能保存扫描结果，请检查设备可用空间。")
                } else {
                    self.finishSuccess(["cancelled": false, "source": "visionkit", "paths": paths])
                }
            }
        }
    }
}

extension IOSDocumentScannerPlugin: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true) { [weak self] in
            self?.finishSuccess(["cancelled": true, "paths": [String]()])
        }
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        let image = info[.originalImage] as? UIImage
        picker.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            guard let image else {
                self.finishError(code: "capture_failed", message: "未能读取拍摄的照片，请重试。")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                if let path = self.saveNormalizedJPEG(image) {
                    self.finishSuccess(["cancelled": false, "source": "camera", "paths": [path]])
                } else {
                    self.finishError(code: "capture_failed", message: "保存拍摄照片失败，请检查可用空间。")
                }
            }
        }
    }
}

extension IOSDocumentScannerPlugin: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            if results.isEmpty {
                self.finishSuccess(["cancelled": true, "paths": [String]()])
                return
            }
            let limited = Array(results.prefix(Self.maxPages))
            let group = DispatchGroup()
            let lock = NSLock()
            var indexedPaths = [(Int, String)]()

            for (index, item) in limited.enumerated() {
                let provider = item.itemProvider
                guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    defer { group.leave() }
                    guard let image = object as? UIImage,
                          let path = self.saveNormalizedJPEG(image) else {
                        return
                    }
                    lock.lock()
                    indexedPaths.append((index, path))
                    lock.unlock()
                }
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                let sorted = indexedPaths.sorted { $0.0 < $1.0 }.map(\.1)
                if sorted.isEmpty {
                    self.finishError(code: "capture_failed", message: "所选图片无法读取，请重新选择常见格式图片。")
                } else {
                    self.finishSuccess(["cancelled": false, "source": "picker", "paths": sorted])
                }
            }
        }
    }
}
