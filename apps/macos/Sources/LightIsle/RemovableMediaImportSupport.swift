import Foundation

enum MediaImportArchiveMode: String, CaseIterable, Identifiable, Sendable {
    case ymd
    case ym
    case preserve

    var id: String { rawValue }
    var label: String {
        switch self {
        case .ymd: return "按年/月/日（YYYY/MM/DD）"
        case .ym: return "按年/月（YYYY/MM）"
        case .preserve: return "保留存储卡原始目录"
        }
    }
}

enum MediaImportTargetCategory: String, CaseIterable, Identifiable, Sendable {
    case auto
    case photos
    case videos

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "自动分流（照片入相册 · 视频入影院）"
        case .photos: return "全部归档至照片目录"
        case .videos: return "全部归档至视频目录"
        }
    }
}

struct DetectedRemovableMediaVolume: Identifiable, Equatable, Sendable {
    var id: String { mountPath }
    let mountPath: String
    let volumeName: String
    let detectedHints: [String]
    let totalBytes: UInt64
    let freeBytes: UInt64
    let isReadOnly: Bool
    let detectedAt: Date

    var hasCameraHints: Bool { !detectedHints.isEmpty }
    var summaryHints: String {
        detectedHints.isEmpty ? "外置可移动介质" : detectedHints.joined(separator: " / ")
    }
}

struct MediaImportScanResult: Decodable, Equatable, Sendable {
    let sourcePath: String
    let volumeName: String
    let totalFiles: Int
    let photoCount: Int
    let rawCount: Int
    let videoCount: Int
    let livePhotoCount: Int
    let totalBytes: Int64
    let detectedHints: [String]?
    let sampleFiles: [String]?
    let truncated: Bool?
}

struct MediaImportJobStatus: Decodable, Equatable, Sendable {
    let jobID: String
    let phase: String
    let sourcePath: String
    let rootID: String
    let generation: UInt64
    let userID: Int64
    let totalFiles: Int
    let processedFiles: Int
    let importedFiles: Int
    let skippedFiles: Int
    let failedFiles: Int
    let totalBytes: Int64
    let processedBytes: Int64
    let importedBytes: Int64
    let currentFile: String?
    let lastError: String?
    let allVerified: Bool
    let targetPrefix: String?
}

/// Pure, thread-safe removable volume detector and IPC error translator.
enum RemovableMediaDetector {
    private static let hintDirectoryNames: [String: String] = [
        "dcim": "DCIM",
        "private": "PRIVATE",
        "dji": "DJI",
        "avchd": "AVCHD",
        "mp_root": "MP_ROOT",
        "cardv": "CardV",
        "movie": "Movie",
    ]
    private static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff",
        "dng", "cr2", "cr3", "nef", "nrw", "arw", "raf", "orf", "rw2",
        "mp4", "mov", "m4v", "avi", "mkv", "mts", "m2ts", "insv",
    ]

    static func pathOverlaps(_ a: String, _ b: String) -> Bool {
        let lhs = URL(fileURLWithPath: a).standardizedFileURL.path
        let rhs = URL(fileURLWithPath: b).standardizedFileURL.path
        guard lhs.hasPrefix("/"), rhs.hasPrefix("/") else { return false }
        return lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    static func isEligibleCandidateMount(
        _ mountPath: String,
        registeredRootPaths: [String],
        diskImageMounts: Set<String>
    ) -> Bool {
        guard StorageVolumeSelection.canInspectExternalVolume(mount: mountPath),
              !diskImageMounts.contains(mountPath) else {
            return false
        }
        return !registeredRootPaths.contains(where: { pathOverlaps(mountPath, $0) })
    }

    static func inspectVolume(
        at url: URL,
        registeredRootPaths: [String],
        diskImageMounts: Set<String>
    ) -> DetectedRemovableMediaVolume? {
        let standardized = url.resolvingSymlinksInPath().standardizedFileURL
        let mountPath = standardized.path
        guard isEligibleCandidateMount(
            mountPath,
            registeredRootPaths: registeredRootPaths,
            diskImageMounts: diskImageMounts
        ) else {
            return nil
        }
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsBrowsableKey,
            .volumeIsReadOnlyKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        ]
        guard let values = try? standardized.resourceValues(forKeys: keys),
              values.volumeIsLocal == true,
              values.volumeIsBrowsable != false else {
            return nil
        }
        let isRemovableOrExternal = values.volumeIsRemovable == true ||
            values.volumeIsEjectable == true ||
            values.volumeIsInternal == false
        guard isRemovableOrExternal else { return nil }

        let probe = probeCameraHintsOrMedia(at: standardized)
        guard !probe.hints.isEmpty || probe.hasMedia || values.volumeIsRemovable == true else {
            return nil
        }
        let name = values.volumeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DetectedRemovableMediaVolume(
            mountPath: mountPath,
            volumeName: (name?.isEmpty == false ? name! : standardized.lastPathComponent),
            detectedHints: probe.hints.sorted(),
            totalBytes: UInt64(max(values.volumeTotalCapacity ?? 0, 0)),
            freeBytes: UInt64(max(values.volumeAvailableCapacity ?? 0, 0)),
            isReadOnly: values.volumeIsReadOnly == true,
            detectedAt: Date()
        )
    }

    private static func probeCameraHintsOrMedia(at rootURL: URL) -> (hints: [String], hasMedia: Bool) {
        let fm = FileManager.default
        guard let topEntries = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], false)
        }
        var hints = Set<String>()
        var hasMedia = false
        var inspected = 0
        for entry in topEntries.prefix(64) {
            inspected += 1
            let res = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if res?.isSymbolicLink == true { continue }
            let nameLower = entry.lastPathComponent.lowercased()
            if res?.isDirectory == true {
                if let label = hintDirectoryNames[nameLower] {
                    hints.insert(label)
                }
                if !hasMedia, inspected <= 32,
                   let nested = try? fm.contentsOfDirectory(
                       at: entry,
                       includingPropertiesForKeys: [.isDirectoryKey],
                       options: [.skipsHiddenFiles]
                   ) {
                    for child in nested.prefix(24) {
                        let ext = child.pathExtension.lowercased()
                        if mediaExtensions.contains(ext) {
                            hasMedia = true
                            break
                        }
                        if let label = hintDirectoryNames[child.lastPathComponent.lowercased()] {
                            hints.insert(label)
                        }
                    }
                }
            } else if mediaExtensions.contains(entry.pathExtension.lowercased()) {
                hasMedia = true
            }
        }
        return (Array(hints), hasMedia)
    }

    static func userFacingError(for code: String) -> String {
        switch code {
        case "source_path_outside_volumes":
            return "源目录必须位于 /Volumes/ 下的外置存储卡或读卡器内，存储卡原件未被修改。"
        case "source_overlaps_nas_root":
            return "所选目录属于已登记的 NAS 存储盘，为避免重复自导入已安全拦截，原有文件未受影响。"
        case "source_not_found", "source_not_directory":
            return "未找到该存储卡或目录（可能已拔出），存储卡原件未受影响。请确认读卡器连接后刷新。"
        case "source_permission_denied":
            return "后台服务缺少读取此存储卡的系统权限，存储卡原件未受影响。请在系统设置「隐私与安全性 → 文件与文件夹」允许轻屿访问可移除宗卷后重试。"
        case "root_not_found", "root_unavailable":
            return "目标 NAS 存储硬盘当前离线或身份已变化，导入已安全停止，存储卡原件未受影响。请检查目标硬盘连接后重试。"
        case "user_not_found", "target_user_location_missing":
            return "所选成员在该硬盘尚未分配对应的照片/视频存储空间，请先在「个人空间」为该成员分配目录后再导入。"
        case "storage_quota_exceeded":
            return "目标成员的可用空间配额不足，导入已安全停止，存储卡原件未受影响。请清理空间或调高配额后重试。"
        case "storage_disk_full":
            return "目标 NAS 硬盘剩余空间不足，导入已安全停止，存储卡原件未受影响。请释放磁盘空间后重试。"
        case "storage_permission_os_denied", "storage_permission_denied":
            return "无法写入目标 NAS 硬盘目录，存储卡原件未受影响。请先在存储管理完成目标硬盘的读写预授权。"
        case "media_import_already_running":
            return "当前已有存储卡导入任务正在运行，请等待完成或先取消后再开始新任务。"
        case "media_import_invalid_subfolder":
            return "子目录名称包含非法字符或层级过深（最多 4 级），请使用普通中英文目录名。"
        case "media_import_cancelled":
            return "导入任务已取消，已完成入库的文件已安全保存，存储卡原件未被修改。"
        case "disk_busy":
            return "当前有其他磁盘操作正在进行，请稍候片刻再重试。"
        default:
            return "导入未能完成（\(code)），存储卡原件未被删除或修改。请检查连接状态后重试。"
        }
    }
}
