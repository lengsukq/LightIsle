import Foundation

@main
struct RunnerTests {
    static func main() async {
        let bounded = await OfflineRecoveryRunner.run(binary: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: [String(repeating: "x", count: 100_000)], timeout: 5, outputLimit: 32_768)
        precondition(bounded.exitCode == 0 && !bounded.timedOut)
        precondition(bounded.truncated && bounded.output.count == 32_768)
        let failure = await OfflineRecoveryRunner.run(binary: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf fixture-error >&2; exit 2"], timeout: 5)
        precondition(failure.exitCode == 2 && String(decoding: failure.output, as: UTF8.self) == "fixture-error")
        let timeout = await OfflineRecoveryRunner.run(binary: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"], timeout: 0.2)
        precondition(timeout.timedOut && timeout.exitCode != 0)
        print("PASS: offline helper pipe draining, output bound, stderr failures and timeout termination")
    }
}
