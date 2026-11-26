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
        print("PASS: removable media import guards, IPC decoder, and user-facing messages")
    }
}
