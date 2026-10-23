import Foundation
import Darwin

struct OfflineRecoveryResult {
    let exitCode: Int32
    let output: Data
    let truncated: Bool
    let timedOut: Bool
}

enum OfflineRecoveryRunner {
    /// Drain while the helper runs: waiting before reading can deadlock once
    /// a bounded JSON inventory fills the pipe. Excess output is discarded.
    static func run(binary: URL, arguments: [String], timeout: TimeInterval = 300,
                    outputLimit: Int = 256 * 1024) async -> OfflineRecoveryResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return OfflineRecoveryResult(exitCode: -1, output: Data(error.localizedDescription.utf8), truncated: false, timedOut: false)
            }
            try? pipe.fileHandleForWriting.close()
            let deadline = DispatchTime.now() + max(0.1, timeout)
            let terminate = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            let force = DispatchWorkItem {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: terminate)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline + 2, execute: force)
            var output = Data()
            var truncated = false
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                let remaining = max(0, outputLimit - output.count)
                output.append(chunk.prefix(remaining))
                if chunk.count > remaining { truncated = true }
            }
            process.waitUntilExit()
            let timedOut = DispatchTime.now() >= deadline
            terminate.cancel()
            force.cancel()
            try? pipe.fileHandleForReading.close()
            return OfflineRecoveryResult(exitCode: process.terminationStatus, output: output,
                                         truncated: truncated, timedOut: timedOut)
        }.value
    }
}
