import Darwin
import Foundation

@main
struct CoreSupervisorCheck {
    static func main() async throws {
        var policy = CoreSupervisorPolicy()
        precondition(policy.nextRetry(at: 10) == nil, "initial boot failure needs manual intervention")
        policy.markReady(at: 10)
        precondition(!policy.recordProbe(healthy: false))
        precondition(!policy.recordProbe(healthy: true))
        precondition(!policy.recordProbe(healthy: false))
        precondition(!policy.recordProbe(healthy: false))
        precondition(policy.recordProbe(healthy: false))
        precondition(policy.nextRetry(at: 30) == 2)
        precondition(policy.nextRetry(at: 40) == 10, "a failed recovery boot still counts")
        policy.markReady(at: 60)
        precondition(policy.nextRetry(at: 70) == 30)
        precondition(policy.nextRetry(at: 100) == nil, "three attempts must exhaust the budget")
        policy.markReady(at: 100)
        precondition(policy.nextRetry(at: 400) == 2, "stable uptime renews the budget")
        precondition(policy.nextRetry(at: 420, startupBlocked: true) == nil)
        precondition(CoreSupervisorPolicy.startupBlocker(exitCode: 72) != nil)
        precondition(CoreSupervisorPolicy.startupBlocker(exitCode: 76) != nil)
        precondition(CorePortListener.listeningPIDs(in: "p20\nn192.168.1.2:16666\np21\nn127.0.0.1:16666\np22\nn*:16666\n", port: 16666) == [21, 22])
        precondition(CoreLifecycleSignal.decode("LIGHTISLE_READY http://127.0.0.1:16666/redirect") == nil)
        precondition(CoreLifecycleSignal.decode("LIGHTISLE_SERVICE_WARNING task_history") != nil)
        try checkCommandWriter()
        print("PASS: Core recovery budget, health failure threshold, startup blockers, and bounded nonblocking control pipe")
        if CommandLine.arguments.count > 1 {
            try await checkSuspendedCore(binary: CommandLine.arguments[1])
            try await checkPortRecovery(binary: CommandLine.arguments[1])
        }
    }

    static func checkCommandWriter() throws {
        let pipe = Pipe()
        let writer = try CoreCommandWriter(pipe.fileHandleForWriting) {}
        let first = Data("stats summary\n".utf8)
        let second = Data("share status\n".utf8)
        try writer.write(contentsOf: first)
        try writer.write(contentsOf: second)
        let result = pipe.fileHandleForReading.readData(ofLength: first.count + second.count)
        precondition(result == first + second, "commands must keep their order")
        writer.close()

        let blocked = Pipe()
        let full = DispatchSemaphore(value: 0)
        let pending = try CoreCommandWriter(blocked.fileHandleForWriting) { full.signal() }
        let bytes = Data(repeating: 65, count: 16 * 1024)
        for _ in 0..<32 {
            do { try pending.write(contentsOf: bytes) }
            catch { break }
        }
        precondition(full.wait(timeout: .now() + 1) == .success, "an unread pipe must cause bounded backpressure")
        pending.close()

        let broken = Pipe()
        let failed = DispatchSemaphore(value: 0)
        let disconnected = try CoreCommandWriter(broken.fileHandleForWriting) { failed.signal() }
        try broken.fileHandleForReading.close()
        try disconnected.write(contentsOf: first)
        precondition(failed.wait(timeout: .now() + 1) == .success, "closed child stdin must not kill AppKit")
        disconnected.close()
    }

    static func checkSuspendedCore(binary: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = CoreHealthProbe()
        defer { probe.close() }
        let (first, writer, endpoint) = try startCore(binary: binary, dataDir: dir, port: 0)
        defer { if first.isRunning { Darwin.kill(first.processIdentifier, SIGKILL) } }
        let ready = await probe.check(endpoint)
        precondition(ready, "the actual loopback health handler must be reachable")
        precondition(Darwin.kill(first.processIdentifier, SIGSTOP) == 0)
        var policy = CoreSupervisorPolicy()
        policy.markReady(at: ProcessInfo.processInfo.systemUptime)
        for n in 1...3 {
            let healthy = await probe.check(endpoint)
            precondition(!healthy)
            precondition(policy.recordProbe(healthy: healthy) == (n == 3))
        }
        precondition(first.isRunning, "an unresponsive child can still be alive")
        writer.close()
        let stopped = await CoreProcessBootstrap.stop(process: first)
        precondition(stopped && !first.isRunning)
        precondition(policy.nextRetry(at: ProcessInfo.processInfo.systemUptime) == 2)
        let (replacement, replacementWriter, restored) = try startCore(binary: binary, dataDir: dir, port: endpoint.port!)
        defer { if replacement.isRunning { Darwin.kill(replacement.processIdentifier, SIGKILL) } }
        let recovered = await probe.check(restored)
        precondition(recovered && restored == endpoint, "replacement must acquire the same port and data directory")
        replacementWriter.close()
        let closed = await CoreProcessBootstrap.stop(process: replacement)
        precondition(closed && replacement.terminationStatus == 0, "parent EOF must close a responsive Core gracefully")
        print("PASS: real suspended Core times out, is stopped before replacement, and returns healthy on the same port")
    }

    static func startCore(binary: String, dataDir: URL, port: Int) throws -> (Process, CoreCommandWriter, URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-data-dir", dataDir.path, "-port", String(port)]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        let writer = try CoreCommandWriter(input.fileHandleForWriting) {}
        try process.run()
        var line = Data()
        let reading = output.fileHandleForReading
        while let next = try reading.read(upToCount: 1), !next.isEmpty, next != Data([10]), line.count < 1024 {
            line.append(next)
        }
        guard case .ready(let endpoint)? = CoreLifecycleSignal.decode(String(decoding: line, as: UTF8.self)) else {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            throw CocoaError(.fileReadCorruptFile)
        }
        return (process, writer, endpoint)
    }

    static func checkPortRecovery(binary: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = CoreHealthProbe()
        defer { probe.close() }
        let (owner, writer, address) = try startCore(binary: binary, dataDir: dir, port: 0)
        defer {
            writer.close()
            if owner.isRunning { Darwin.kill(owner.processIdentifier, SIGKILL) }
        }
        let port = address.port!
        let target = try CorePortListener.inspect(port: port)
        precondition(target.pid == owner.processIdentifier)
        let healthyBeforeConfirmation = await probe.check(address)
        precondition(healthyBeforeConfirmation, "inspection must leave the listener untouched")
        try target.forceStop()
        owner.waitUntilExit()
        precondition(owner.terminationStatus == SIGKILL)

        let (replacement, replacementWriter, restored) = try startCore(binary: binary, dataDir: dir, port: port)
        defer {
            replacementWriter.close()
            if replacement.isRunning { Darwin.kill(replacement.processIdentifier, SIGKILL) }
        }
        do {
            try target.forceStop()
            preconditionFailure("a stale confirmation must not stop the new listener")
        } catch CorePortListener.Failure.changed {}
        let healthyAfterRecovery = await probe.check(restored)
        precondition(healthyAfterRecovery && restored == address)
        replacementWriter.close()
        _ = await CoreProcessBootstrap.stop(process: replacement)
        print("PASS: inspect leaves the listener running, confirmed force-stop frees the port, and stale confirmation protects the replacement")
    }
}
