import Foundation

/// Pure presentation and privileged child-process invocation for offline
/// metadata recovery. AppModel remains responsible for user consent, Touch ID,
/// stopping/restarting Core, and publishing UI state.
enum NativeMetadataRecovery {
    static func previewConfirmation(_ preview: NASMetadataRecoveryPreview) -> String {
        previewLabels.map { item in
            let count = preview.counts[item.0]
            return "\(item.1)：当前 \(displayPreviewCount(count?.current)) → 恢复后 \(displayPreviewCount(count?.staged))"
        }.joined(separator: "\n")
    }

    private static let previewLabels: [(String, String)] = [
        ("accounts.users", "账号"),
        ("accounts.fileGrants", "旧目录授权"),
        ("accounts.rootFileGrants", "共享根授权"),
        ("accounts.rootFileShares", "临时目录分享"),
        ("gallery.privateAlbums", "私人相册"),
        ("gallery.privateAlbumItems", "私人相册项目"),
        ("gallery.favorites", "收藏"),
        ("gallery.manualAlbums", "手工相册"),
        ("gallery.indexedAssets", "图库索引项目"),
        ("cinema.manualTitles", "手工影视标题"),
        ("cinema.indexedFilms", "影视索引项目"),
        ("tasks.journal", "任务摘要"),
        ("tasks.history", "任务历史")
    ]

    private static func displayPreviewCount(_ count: Int64?) -> String {
        count.map { $0.formatted() } ?? "未知"
    }

    static func runPreview(dataDir: String, stage: String) async -> NASMetadataRecoveryPreview {
        let failure = NASMetadataRecoveryPreview(schemaVersion: 1, operation: "preview", status: "failed",
            verified: false, manifestSHA256: "", counts: [:], warnings: [],
            error: NASMetadataPreviewError(code: "preview_unavailable", message: "无法验证恢复预览，当前数据库未修改。"))
        guard let binary = Bundle.main.resourceURL?.appendingPathComponent("core/lightisle-recovery"),
              FileManager.default.isExecutableFile(atPath: binary.path) else { return failure }
        let result = await OfflineRecoveryRunner.run(binary: binary, arguments: [
            "--data-dir", dataDir, "--operation", "preview", "--stage", stage,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)
        ], timeout: 40, outputLimit: 64 * 1024)
        guard !result.timedOut, !result.truncated, result.exitCode == 0,
              let response = try? JSONDecoder().decode(NASMetadataRecoveryPreview.self, from: result.output) else {
            return failure
        }
        return response
    }

    static func runOperation(operation: String, dataDir: String, stage: String, confirmation: String,
                             expectedManifestSHA256: String? = nil) async -> String {
        guard let binary = Bundle.main.resourceURL?.appendingPathComponent("core/lightisle-recovery"),
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            return "内置离线恢复程序缺失，数据未更改。"
        }
        var arguments = [
            "--data-dir", dataDir, "--operation", operation, "--stage", stage,
            "--confirm", confirmation, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)
        ]
        if let expectedManifestSHA256 {
            arguments += ["--expected-manifest-sha256", expectedManifestSHA256]
        }
        let result = await OfflineRecoveryRunner.run(binary: binary, arguments: arguments)
        let text = String(decoding: result.output.prefix(4096), as: UTF8.self)
        if result.timedOut {
            return "离线操作超过等待时间，已停止工具。请检查是否需要修复中断的恢复。"
        }
        if result.exitCode == 0 {
            if operation == "activate" {
                return "数据库已恢复，之前版本已保留为可回退记录。共享文件未覆盖；请按需重新扫描图库与影视索引。"
            }
            return "离线数据库操作成功：\(text)"
        }
        if operation == "activate" && text.contains("staged_metadata_changed_since_preview") {
            return "恢复目录在预览后发生变化，未应用数据库。请重新检查恢复影响。"
        }
        if operation == "activate" {
            return "离线数据库恢复未能完成；当前或回退版本均会保留。请检查恢复状态后重试。"
        }
        return "离线数据库操作未成功：\(text)。如提示恢复中断，请选择“修复中断的恢复”。"
    }

    static var privateMetadataDirectory: String? {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false))?
            .appendingPathComponent("LightIsle").path
    }
}
