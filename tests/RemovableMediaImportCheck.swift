import Foundation

// Swift 6 smoke check for removable media candidate filtering, IPC framing, and error mapping.
@main
struct RemovableMediaImportCheck {
    static func main() {
        let roots = ["/Volumes/NAS_PRIMARY/LightIsle", "/Users/owner/LightIsle"]
        let dmgMounts: Set<String> = ["/Volumes/LightIsleInstaller"]

        precondition(
            RemovableMediaDetector.isEligibleCandidateMount(
                "/Volumes/EOS_DIGITAL",
                registeredRootPaths: roots,
                diskImageMounts: dmgMounts
            ),
            "expected independent SD card volume to be eligible"
        )
        precondition(
            !RemovableMediaDetector.isEligibleCandidateMount(
                "/Volumes/NAS_PRIMARY",
                registeredRootPaths: roots,
                diskImageMounts: dmgMounts
            ),
            "expected parent volume of registered NAS root to be rejected"
        )
        precondition(
            !RemovableMediaDetector.isEligibleCandidateMount(
                "/Volumes/LightIsleInstaller",
                registeredRootPaths: roots,
                diskImageMounts: dmgMounts
            ),
            "expected mounted DMG to be excluded"
        )
        precondition(
            !RemovableMediaDetector.isEligibleCandidateMount(
                "/Users/owner/Desktop",
                registeredRootPaths: roots,
                diskImageMounts: dmgMounts
            ),
            "expected non-/Volumes path to be rejected"
        )

        let decoded = CoreIPCDomainEvent.decode("LIGHTISLE_MEDIA_IMPORT eyJ0ZXN0IjoxfQ")
        precondition(decoded == .subsystem(.mediaImport("eyJ0ZXN0IjoxfQ")), "failed to decode LIGHTISLE_MEDIA_IMPORT event")

        for code in [
            "source_overlaps_nas_root",
            "source_path_outside_volumes",
            "storage_quota_exceeded",
            "root_unavailable",
            "media_import_cancelled",
        ] {
            let msg = RemovableMediaDetector.userFacingError(for: code)
            precondition(!msg.isEmpty && (msg.contains("原件") || msg.contains("未受影响")), "user-facing error must reassure originals are safe: \(code)")
        }

        // 1. Safe-eject cross-volume guard: verified status for Card A must NEVER allow ejecting Card B.
        let cardA = "/Volumes/EOS_DIGITAL"
        let cardB = "/Volumes/DJI_DRONE"
        let verifiedCardA = MediaImportJobStatus(
            phase: "completed",
            sourcePath: cardA,
            totalFiles: 12,
            processedFiles: 12,
            importedFiles: 10,
            skippedFiles: 2,
            failedFiles: 0,
            allVerified: true
        )
        let normalScanA = MediaImportScanResult(
            sourcePath: cardA,
            volumeName: "EOS_DIGITAL",
            totalFiles: 12,
            truncated: false
        )
        precondition(
            RemovableMediaImportPolicy.canSafeEject(
                selectedMountPath: cardA,
                jobStatus: verifiedCardA,
                scanResult: normalScanA,
                isImporting: false
            ),
            "expected verified job matching selected mount to allow safe eject"
        )
        precondition(
            !RemovableMediaImportPolicy.canSafeEject(
                selectedMountPath: cardB,
                jobStatus: verifiedCardA,
                scanResult: normalScanA,
                isImporting: false
            ),
            "cross-volume eject guard must block ejecting Card B using Card A's verified job"
        )
        precondition(
            !RemovableMediaImportPolicy.canSafeEject(
                selectedMountPath: cardA,
                jobStatus: verifiedCardA,
                scanResult: normalScanA,
                isImporting: true
            ),
            "must block safe eject while importing or starting"
        )

        // 2. Truncated scan/job guard: exceeding 50,000 files must strictly forbid safe eject.
        let truncatedScanA = MediaImportScanResult(
            sourcePath: cardA,
            volumeName: "EOS_DIGITAL",
            totalFiles: 50_000,
            truncated: true
        )
        precondition(
            !RemovableMediaImportPolicy.canSafeEject(
                selectedMountPath: cardA,
                jobStatus: verifiedCardA,
                scanResult: truncatedScanA,
                isImporting: false
            ),
            "truncated scan must forbid safe eject even if jobStatus.allVerified is true"
        )
        let truncatedJobA = MediaImportJobStatus(
            phase: "completed",
            sourcePath: cardA,
            totalFiles: 50_000,
            processedFiles: 50_000,
            importedFiles: 50_000,
            failedFiles: 0,
            allVerified: true,
            truncated: true
        )
        precondition(
            !RemovableMediaImportPolicy.canSafeEject(
                selectedMountPath: cardA,
                jobStatus: truncatedJobA,
                scanResult: normalScanA,
                isImporting: false
            ),
            "truncated job status must forbid safe eject"
        )
        let truncatedTitle = RemovableMediaImportPolicy.phaseTitle(for: verifiedCardA, scanTruncated: true)
        precondition(
            truncatedTitle != "导入与核验已完成",
            "truncated import must not claim full verification completion"
        )

        // 3. Partial failure guards & honest phase titles (both completed_with_errors and failedFiles > 0).
        let completedWithErrors = MediaImportJobStatus(
            phase: "completed_with_errors",
            sourcePath: cardA,
            totalFiles: 20,
            processedFiles: 20,
            importedFiles: 17,
            failedFiles: 3,
            allVerified: false
        )
        precondition(
            !RemovableMediaImportPolicy.canSafeEject(
                selectedMountPath: cardA,
                jobStatus: completedWithErrors,
                scanResult: normalScanA,
                isImporting: false
            ),
            "completed_with_errors must forbid safe eject"
        )
        precondition(
            RemovableMediaImportPolicy.phaseTitle(for: completedWithErrors) == "部分文件导入未完成（失败 3 项）",
            "completed_with_errors title must honestly show failed count"
        )

        let legacyPartialCompleted = MediaImportJobStatus(
            phase: "completed",
            sourcePath: cardA,
            totalFiles: 10,
            processedFiles: 10,
            importedFiles: 8,
            failedFiles: 2,
            allVerified: true
        )
        precondition(
            !RemovableMediaImportPolicy.canSafeEject(
                selectedMountPath: cardA,
                jobStatus: legacyPartialCompleted,
                scanResult: normalScanA,
                isImporting: false
            ),
            "failedFiles > 0 must forbid safe eject even if phase == completed"
        )
        precondition(
            RemovableMediaImportPolicy.phaseTitle(for: legacyPartialCompleted) == "部分文件导入未完成（失败 2 项）",
            "phase == completed with failedFiles > 0 must never display '导入与核验已完成'"
        )
        precondition(
            RemovableMediaImportPolicy.phaseTitle(for: verifiedCardA, scanTruncated: false) == "导入与核验已完成",
            "fully verified non-truncated completion must show completed title"
        )

        // 4. Custom subdirectory option inclusion & category validation fallback.
        let detected = [
            DetectedRemovableMediaVolume(
                mountPath: cardA,
                volumeName: "EOS_DIGITAL",
                detectedHints: ["DCIM"],
                totalBytes: 1_000,
                freeBytes: 500,
                isReadOnly: false,
                detectedAt: Date()
            )
        ]
        let customSubdir = "/Volumes/EOS_DIGITAL/DCIM/100CANON"
        let options = RemovableMediaImportPolicy.sourceOptionEntries(
            detectedVolumes: detected,
            selectedPath: customSubdir
        )
        precondition(
            options.contains(where: { $0.value == customSubdir }),
            "manual subdirectory selection must be dynamically added to picker options"
        )
        precondition(
            !RemovableMediaImportPolicy.canSafeEject(
                selectedMountPath: customSubdir,
                jobStatus: MediaImportJobStatus(phase: "completed", sourcePath: customSubdir, totalFiles: 3, processedFiles: 3, importedFiles: 3, failedFiles: 0, allVerified: true),
                scanResult: nil,
                isImporting: false
            ),
            "subdirectory import must not enable full-volume safe eject"
        )
        precondition(
            RemovableMediaImportPolicy.validatedCategory(.videos, allocatedLocationCategories: ["photos"]) == .auto,
            "disallowed category must fall back to .auto when switching target"
        )
        precondition(
            RemovableMediaImportPolicy.validatedCategory(.photos, allocatedLocationCategories: ["photos"]) == .photos,
            "allowed category must be preserved"
        )

        print("PASS: removable media import guards, safe-eject protections, phase titles, picker fallback, and category validation")
    }
}
