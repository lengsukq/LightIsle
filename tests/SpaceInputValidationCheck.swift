import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct SpaceInputValidationCheck {
    static func main() {
        // 1. QuotaInputValidator tests
        check(QuotaInputValidator.validateGiB("") == .unlimited, "empty string should be unlimited")
        check(QuotaInputValidator.validateGiB("  ") == .unlimited, "whitespace string should be unlimited")
        check(QuotaInputValidator.validateGiB("0") == .unlimited, "0 GiB should be unlimited")
        check(QuotaInputValidator.validateGiB("100") == .valid(bytes: 100 * (1 << 30)), "100 GiB should equal 100 * 2^30 bytes")
        check(QuotaInputValidator.validateGiB("1048576") == .valid(bytes: 1_048_576 * (1 << 30)), "max 1048576 GiB should be valid")
        check(!QuotaInputValidator.validateGiB("1048577").isValid, "1048577 GiB should be rejected")
        check(!QuotaInputValidator.validateGiB("-5").isValid, "negative GiB should be rejected")
        check(!QuotaInputValidator.validateGiB("abc").isValid, "non-numeric GiB should be rejected")
        check(!QuotaInputValidator.validateGiB("9999999999").isValid, "huge integer must not overflow crash and must be rejected")

        let lowQuota = QuotaInputValidator.validateGiB("10", currentUsedBytes: 25 * (1 << 30))
        check(lowQuota.isValid, "quota below current usage should still be valid with warning")
        check(lowQuota.warningMessage != nil, "quota below current usage should emit warning message")

        // 2. AccountInputValidator tests
        check(AccountInputValidator.validateUsername("") == .empty, "empty username should be .empty")
        check(!AccountInputValidator.validateUsername("ab").isValid, "2-char username should be invalid")
        check(AccountInputValidator.validateUsername("alice_01.home-nas").isValid, "valid username should pass")
        check(!AccountInputValidator.validateUsername("alice!").isValid, "username with '!' should be invalid")
        check(!AccountInputValidator.validateUsername(" alice ").isValid, "username with leading/trailing space should be invalid")

        check(AccountInputValidator.validatePassword("") == .empty, "empty password should be .empty")
        check(!AccountInputValidator.validatePassword("short123").isValid, "short password should be invalid")
        check(!AccountInputValidator.validatePassword(" valid-twelve-char ").isValid, "password with leading/trailing whitespace should be invalid")
        check(AccountInputValidator.validatePassword("valid-twelve-char").isValid, "17-char password should pass")

        // 3. SpaceCategoryPresentation & StorageSwitchStagePresentation tests
        check(SpaceCategoryPresentation.detailLabel(for: "files") == "文件（files）", "files detail label")
        check(SpaceCategoryPresentation.detailLabel(for: "photos") == "相册（photos）", "photos detail label")
        check(SpaceCategoryPresentation.detailLabel(for: "videos") == "影视（videos）", "videos detail label")
        check(!SpaceCategoryPresentation.enforcementDescription("pending").contains("enforcement="), "enforcement description should be humanized")

        let copyingStage = StorageSwitchStagePresentation.describe(
            phase: "copying",
            mode: "migrate",
            copiedBytes: 512 * (1 << 20),
            totalBytes: 1024 * (1 << 20),
            verifiedFiles: 5,
            totalFiles: 10,
            deletedSourceFiles: 0
        )
        check(copyingStage.stepIndex == 2 && copyingStage.totalSteps == 5, "copying stage should be step 2/5")
        check(copyingStage.fraction == 0.5, "copying stage fraction should be 0.5")
        check(StorageSwitchStagePresentation.mediaAndShareImpactNote(for: "migrate").contains("自动迁移到新盘"), "migrate mode note should state verified media records migrate")
        check(StorageSwitchStagePresentation.mediaAndShareImpactNote(for: "empty").contains("空白启用模式不复制旧盘文件"), "empty mode note should state old records stay on old disk")

        print("SpaceInputValidationCheck passed")
    }
}
