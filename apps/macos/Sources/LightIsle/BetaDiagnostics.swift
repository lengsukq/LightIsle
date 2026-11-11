import AppKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

actor BetaDiagnostics {
    static let shared = BetaDiagnostics()
    private static let fileLimit = 5 * 1_048_576
    private static let retainedFiles = 3
    private let formatter = ISO8601DateFormatter()
    private let fractionalFormatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()
    private var retryAt = Date.distantPast

    enum Lifecycle: String, Sendable {
        case coreStarting = "core_starting"
        case coreReady = "core_ready"
        case coreFailed = "core_failed"
        case coreStartupBlocked = "core_startup_blocked"
        case coreStopped = "core_stopped"
    }

    func record(_ lifecycle: Lifecycle, dataDirectory: String?, version: String) {
        guard let dataDirectory, Date() >= retryAt else { return }
        do {
            let directory = try privateDirectory(dataDirectory, source: "mac")
            let event = [
                "time": formatter.string(from: Date()),
                "version": version,
                "level": lifecycle == .coreFailed || lifecycle == .coreStartupBlocked ? "ERROR" : "INFO",
                "component": "mac",
                "operation": "core_lifecycle",
                "code": lifecycle.rawValue,
            ]
            var bytes = try JSONSerialization.data(withJSONObject: event)
            bytes.append(10)
            let handle = try openFile(log(directory, 0), writing: true)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            if size + UInt64(bytes.count) > Self.fileLimit {
                try rotate(directory)
                let next = try openFile(log(directory, 0), writing: true)
                defer { try? next.close() }
                try next.write(contentsOf: bytes)
            } else {
                try handle.write(contentsOf: bytes)
            }
        } catch {
            retryAt = Date().addingTimeInterval(60)
        }
    }

    func report(dataDirectory: String?) throws -> String {
        guard let dataDirectory else { throw CocoaError(.fileNoSuchFile) }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        var events: [(Date, [String: Any])] = []
        for source in ["core", "mac"] {
            guard let directory = try? privateDirectory(dataDirectory, source: source, create: false) else { continue }
            for index in 0..<Self.retainedFiles {
                guard let handle = try? openFile(log(directory, index), writing: false) else { continue }
                defer { try? handle.close() }
                guard let bytes = try handle.read(upToCount: Self.fileLimit + 1), bytes.count <= Self.fileLimit else { continue }
                for line in bytes.split(separator: 10) where line.count <= 1024 {
                    guard let decoded = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let safe = safeEvent(decoded), safe.0 >= cutoff else { continue }
                    events.append(safe)
                }
                events.sort { $0.0 > $1.0 }
                if events.count > 2000 { events.removeLast(events.count - 2000) }
            }
        }
        let report: [String: Any] = [
            "schema": 1,
            "source": "host",
            "exportedAt": formatter.string(from: Date()),
            "events": events.reversed().map { $0.1 },
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func safeEvent(_ value: [String: Any]) -> (Date, [String: Any])? {
        guard let time = value["time"] as? String,
              let date = fractionalFormatter.date(from: time) ?? formatter.date(from: time) else { return nil }
        var safe: [String: Any] = ["time": fractionalFormatter.string(from: date)]
        for field in ["version", "level", "component", "operation", "code"] {
            if let item = value[field] as? String, item.range(of: #"\A[a-zA-Z0-9_.-]{1,64}\z"#, options: .regularExpression) != nil {
                safe[field] = item
            }
        }
        for field in ["requestID", "taskID"] {
            if let item = value[field] as? String, item.range(of: #"\A[a-f0-9-]{16,64}\z"#, options: .regularExpression) != nil {
                safe[field] = item
            }
        }
        if let status = value["status"] as? Int, (100...599).contains(status) { safe["status"] = status }
        if let elapsed = value["elapsedMs"] as? Int, elapsed >= 0 { safe["elapsedMs"] = elapsed }
        return (date, safe)
    }

    private func privateDirectory(_ base: String, source: String, create: Bool = true) throws -> URL {
        var directory = URL(fileURLWithPath: base, isDirectory: true)
        for part in ["diagnostics", source] {
            directory.appendPathComponent(part, isDirectory: true)
            if create && !FileManager.default.fileExists(atPath: directory.path) {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                } catch CocoaError.fileWriteFileExists { }
            }
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
                throw CocoaError(.fileReadNoPermission)
            }
        }
        return directory
    }

    private func log(_ directory: URL, _ index: Int) -> URL {
        directory.appendingPathComponent("events-\(index).jsonl")
    }

    private func openFile(_ url: URL, writing: Bool) throws -> FileHandle {
        let flags = O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (writing ? O_WRONLY | O_CREAT | O_APPEND : O_RDONLY)
        let fd = open(url.path, flags, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1 else {
            close(fd)
            throw CocoaError(.fileReadNoPermission)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func rotate(_ directory: URL) throws {
        for index in stride(from: Self.retainedFiles - 1, through: 1, by: -1) {
            if rename(log(directory, index - 1).path, log(directory, index).path) != 0 && errno != ENOENT {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }
}

struct BetaDiagnosticControls: View {
    @ObservedObject var model: AppModel
    @State private var preview: String?
    @State private var notice: String?
    @State private var loading = false

    var body: some View {
        AppleSettingsGroup(title: "Beta 故障报告", footer: "报告包含最近 24 小时的本机事件，可预览和手动保存。") {
            HStack {
                Button("预览故障报告") { loadReport() }.disabled(loading)
                Button("开启 30 分钟调试记录") { enableDebug() }.disabled(model.state != .online)
            }
            if let notice { Text(notice).font(.footnote) }
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Beta 故障报告").font(.headline)
                ScrollView { Text(preview ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Spacer()
                    Button("关闭") { preview = nil }
                    Button("保存报告") { saveReport() }.keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 600, height: 460)
        }
    }

    private func loadReport() {
        loading = true
        Task {
            defer { loading = false }
            do { preview = try await BetaDiagnostics.shared.report(dataDirectory: NativeMetadataRecovery.privateMetadataDirectory) }
            catch { notice = "无法读取本机报告，请检查系统盘权限后重试。" }
        }
    }

    private func saveReport() {
        guard let preview else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "lightisle-host-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try preview.write(to: url, atomically: true, encoding: .utf8) }
        catch { notice = "无法保存报告，请选择可写入的目录。" }
    }

    private func enableDebug() {
        do {
            guard let writer = model.coreCommands else { throw CocoaError(.fileWriteUnknown) }
            try writer.write(contentsOf: Data("diagnostics debug\n".utf8))
            notice = "已请求开启调试记录，30 分钟后自动结束。"
        } catch { notice = "无法发送调试指令，请确认 Core 仍在运行。" }
    }
}

@MainActor
func recordBetaLifecycle(_ event: BetaDiagnostics.Lifecycle) {
    let directory = NativeMetadataRecovery.privateMetadataDirectory
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    Task { await BetaDiagnostics.shared.record(event, dataDirectory: directory, version: version) }
}
