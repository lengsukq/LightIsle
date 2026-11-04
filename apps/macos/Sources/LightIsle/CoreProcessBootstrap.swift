import Foundation
import Darwin

/// A single launch generation owns its pipes and child process. AppModel
/// retains state and IPC authorization; this helper owns only process setup
/// and the orderly shutdown escalation policy.
struct CoreProcessBootstrap {
    let process: Process
    let generation: UUID
    let input: Pipe
    let output: Pipe

    static func make(
        port: Int,
        thumbnailCacheMiB: Int
    ) -> CoreProcessBootstrap? {
        let executable = ProcessInfo.processInfo.environment["LIGHTISLE_CORE_PATH"]
            .map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.resourceURL?.appendingPathComponent("core/lightisled")
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path)
        else { return nil }

        let web = ProcessInfo.processInfo.environment["LIGHTISLE_WEB_ROOT"]
            .map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.resourceURL?.appendingPathComponent("web")

        let process = Process()
        process.executableURL = executable
        let arguments = [
            "-port", String(port),
            "-web-root", web?.path ?? "",
            "-thumbnail-cache-bytes", String(thumbnailCacheMiB * 1_048_576),
        ]
        process.arguments = arguments

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        return CoreProcessBootstrap(
            process: process,
            generation: UUID(),
            input: input,
            output: output
        )
    }

    static func stop(process: Process, input: Pipe?, output: Pipe?) async {
        if let input = input?.fileHandleForWriting {
            // Child might already have exited; a broken pipe is not fatal.
            try? input.write(contentsOf: Data("shutdown\n".utf8))
            input.closeFile()
        }
        // HTTP requests and listeners must exit before we escalate signals.
        for _ in 0..<40 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            process.terminate()
            for _ in 0..<15 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            for _ in 0..<10 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        output?.fileHandleForReading.readabilityHandler = nil
    }
}
