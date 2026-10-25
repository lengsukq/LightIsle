import Foundation

/// On-demand SMART elevation, owned by the Mac App because only it can
/// present the macOS authorization dialog (the Go core runs unprivileged and
/// the web cannot show system dialogs).
///
/// Two collection paths, tried in order:
/// 1. Silent `sudo -n smartctl …` — succeeds when the user installed the
///    optional NOPASSWD sudoers rule documented in the in-app guide.
/// 2. `do shell script … with administrator privileges` — shows the system
///    password dialog; sudo caches the approval for ~5 minutes so consecutive
///    disks rarely prompt again.
///
/// The elevated command is a fixed template whose only variable part is the
/// BSD disk number, validated by regex. No user-controlled string reaches
/// the shell, the password never passes through app code, and nothing is
/// installed or left running afterwards.
enum SmartElevation {
    static let candidates = ["/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl"]

    enum ElevationError: LocalizedError {
        case binaryMissing
        case deviceInvalid
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .binaryMissing:
                return "未安装 smartmontools，无法读取详细健康信息。可执行 brew install smartmontools 后重试。"
            case .deviceInvalid:
                return "磁盘标识无效，已拒绝提权读取。"
            case .cancelled:
                return nil // the user dismissed the system dialog; stay silent
            case .failed(let reason):
                return "SMART 提权读取失败：\(reason)"
            }
        }
    }

    static func locateBinary() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func diskNumber(_ device: String) throws -> Int {
        // Accept exactly "diskN" or "diskNsM"; the digits are the only part
        // that reaches the elevated command line, so parsing is strict.
        guard device.hasPrefix("disk") else { throw ElevationError.deviceInvalid }
        let remainder = device.dropFirst("disk".count)
        let digits = remainder.prefix(while: \.isNumber)
        guard !digits.isEmpty, let number = Int(digits) else {
            throw ElevationError.deviceInvalid
        }
        let suffix = remainder.dropFirst(digits.count)
        if suffix.isEmpty {
            return number
        }
        guard suffix.hasPrefix("s"), let partition = Int(suffix.dropFirst()),
              String(partition) == suffix.dropFirst() else {
            throw ElevationError.deviceInvalid
        }
        return number
    }

    /// Collects a `smartctl --json -a /dev/diskN` report via sudo -n first,
    /// then the system password dialog. Synchronous and blocking; call from a
    /// detached task.
    static func collect(device: String) throws -> Data {
        let digits = try diskNumber(device)
        guard let binary = locateBinary() else { throw ElevationError.binaryMissing }

        let sudoOutcome = runProcess("/usr/bin/sudo", ["-n", binary, "--json", "-a", "/dev/disk\(digits)"], timeout: 8)
        if let data = sudoOutcome.output, isUsableSMARTJSON(data) {
            return data
        }
        let script = "do shell script \(appleScriptQuoted("\(binary) --json -a /dev/disk\(digits)")) with administrator privileges"
        let outcome = runProcess("/usr/bin/osascript", ["-e", script], timeout: 150)
        guard let data = outcome.output, isUsableSMARTJSON(data) else {
            let message = outcome.error ?? ""
            if message.contains("User canceled") || message.contains("user canceled") ||
                message.contains("(-128)") || message.contains("(-6002)") {
                throw ElevationError.cancelled
            }
            throw ElevationError.failed(message.isEmpty ? "命令未返回有效结果。" : String(message.prefix(200)))
        }
        return data
    }

    private static func isUsableSMARTJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["device_name"] != nil || object["smart_status"] != nil ||
            object["temperature"] != nil || object["nvme_smart_health_information_log"] != nil
    }

    private struct ProcessOutcome {
        var output: Data?
        var error: String?
    }

    private static func runProcess(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) -> ProcessOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        // A minimal environment; the authorization comes from the system, and
        // proxy variables must not influence the control path.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return ProcessOutcome(output: nil, error: error.localizedDescription)
        }
        let deadline = DispatchTime.now() + timeout
        var outputData = Data()
        var errorData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        group.enter()
        queue.async { outputData = readAll(stdout.fileHandleForReading, upTo: 1 << 20) ; group.leave() }
        group.enter()
        queue.async { errorData = readAll(stderr.fileHandleForReading, upTo: 16 << 10) ; group.leave() }
        _ = group.wait(timeout: deadline)
        // Hard stop at the deadline; an escalated dialog waits for the user.
        if process.isRunning && DispatchTime.now() >= deadline {
            process.terminate()
        }
        process.waitUntilExit()

        let truncatedError = String(data: errorData, encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
            return ProcessOutcome(output: outputData.isEmpty ? nil : outputData, error: nil)
        }
        return ProcessOutcome(output: nil, error: truncatedError.isEmpty
            ? "退出码 \(process.terminationStatus)"
            : truncatedError)
    }

    private static func readAll(_ handle: FileHandle, upTo limit: Int) -> Data {
        var data = Data()
        while data.count < limit {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }

    private static func appleScriptQuoted(_ command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
