import Foundation

// Local, read-only diagnostics. Never invokes tmutil commands that change
// destinations, exclusions, backup schedules or the user's files.
struct TimeMachineDiagnostics: Sendable {
    enum Inclusion: String, Sendable {
        case included = "显示为包含"
        case excluded = "已排除"
        case unknown = "无法核实"
    }

    let destinationNames: [String]
    let destinationKnown: Bool
    let latestBackupPath: String?
    let sharedFolder: Inclusion
    let metadataFolder: Inclusion
    let detail: String?

    var summary: String {
        if !destinationKnown { return "无法读取 Time Machine 配置" }
        return destinationNames.isEmpty ? "没有配置备份磁盘" : "已配置 \(destinationNames.count) 个备份目标（不代表备份成功）"
    }

    static func read(sharedPath: String?) -> TimeMachineDiagnostics {
        let destination = command(["destinationinfo", "-X"])
        let names: [String]?
        if destination.exitCode == 0 {
            names = parseDestinationNames(destination.output)
        } else {
            names = nil
        }
        let metadataPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LightIsle").path
        let metadata = inclusion(for: metadataPath)
        let shared = sharedPath.flatMap { !$0.isEmpty ? inclusion(for: $0) : nil } ?? .unknown
        let latest = command(["latestbackup"])
        let latestPath: String?
        if latest.exitCode == 0 {
            let output = String(decoding: latest.output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            latestPath = output.hasPrefix("/") && output.utf8.count <= 4096 ? output : nil
        } else {
            latestPath = nil
        }
        let error = names == nil ? "无法核实备份目标；请在系统设置的 Time Machine 中检查。" : nil
        return TimeMachineDiagnostics(
            destinationNames: names ?? [], destinationKnown: names != nil, latestBackupPath: latestPath,
            sharedFolder: shared, metadataFolder: metadata, detail: error
        )
    }

    // The -X option produces a property list on supported macOS versions.
    // An unexpected output format is UNKNOWN, never a false 'protected'.
    static func parseDestinationNames(_ data: Data) -> [String]? {
        guard data.count <= 128 * 1024,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let values = root["Destinations"] as? [[String: Any]] else { return nil }
        return values.prefix(32).map {
            ($0["Name"] as? String)?.prefix(120).description ?? "未命名目的地"
        }
    }

    static func parseExclusion(_ output: Data) -> Inclusion {
        let text = String(decoding: output.prefix(4096), as: UTF8.self)
        if text.contains("[Excluded]") { return .excluded }
        if text.contains("[Included]") { return .included }
        return .unknown
    }

    private static func inclusion(for path: String) -> Inclusion {
        guard FileManager.default.fileExists(atPath: path) else { return .unknown }
        let result = command(["isexcluded", path])
        return result.exitCode == 0 ? parseExclusion(result.output) : .unknown
    }

    private static func command(_ args: [String]) -> (exitCode: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // tmutil -X/ isexcluded normally return promptly; the diagnostic must
        // never stall the settings UI on a disconnected backup destination.
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            return (-1, Data())
        }
        if completed.wait(timeout: .now() + 5) == .timedOut {
            if process.isRunning { process.terminate() }
            return (-1, Data())
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, Data(output.prefix(128 * 1024)))
    }
}
