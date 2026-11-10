import Darwin
import Foundation

struct CorePortListener: Equatable, Sendable {
    let port: Int
    let pid: pid_t
    let executable: String
    private let startSeconds: UInt64
    private let startMicroseconds: UInt64

    var name: String { URL(fileURLWithPath: executable).lastPathComponent }

    enum Failure: LocalizedError {
        case unidentified, protected, changed, stopFailed

        var errorDescription: String? {
            switch self {
            case .unidentified: return "未能确认唯一的端口占用进程。可以换一个端口，或重试当前端口。"
            case .protected: return "无法安全停止这个进程。请换端口，或在原应用中停止服务后重试。"
            case .changed: return "端口占用情况已变化。请重新查看占用者，或重试当前端口。"
            case .stopFailed: return "未能停止占用进程。请换端口，或在原应用中停止服务后重试。"
            }
        }
    }

    static func inspect(port: Int) throws -> Self {
        guard (1024...65535).contains(port) else { throw Failure.unidentified }
        let command = Process()
        let output = Pipe()
        command.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        command.arguments = ["-b", "-w", "-nP", "-a", "-i4TCP:\(port)", "-sTCP:LISTEN", "-Fpn"]
        command.standardOutput = output
        command.standardError = FileHandle.nullDevice
        do { try command.run() } catch { throw Failure.unidentified }
        let report = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else { throw Failure.unidentified }
        let pids = listeningPIDs(in: String(decoding: report, as: UTF8.self), port: port)
        guard pids.count == 1, let pid = pids.first else { throw Failure.unidentified }
        guard let owner = snapshot(pid: pid, port: port) else { throw Failure.protected }
        return owner
    }

    static func listeningPIDs(in report: String, port: Int) -> Set<pid_t> {
        // A LAN-only socket on the same number does not block the Core's loopback listener.
        let addresses = ["n127.0.0.1:\(port)", "n*:\(port)"]
        var pids: Set<pid_t> = []
        var current: pid_t?
        for line in report.split(whereSeparator: \.isNewline) {
            if line.first == "p" { current = pid_t(line.dropFirst()) }
            if addresses.contains(String(line)), let current { pids.insert(current) }
        }
        return pids
    }

    func forceStop() throws {
        guard (try? Self.inspect(port: port)) == self,
              Self.snapshot(pid: pid, port: port) == self else { throw Failure.changed }
        guard Darwin.kill(pid, SIGKILL) == 0 else { throw Failure.stopFailed }
        for _ in 0..<20 {
            if Self.snapshot(pid: pid, port: port) != self { return }
            usleep(50_000)
        }
        guard Self.snapshot(pid: pid, port: port) != self else { throw Failure.stopFailed }
    }

    private static func snapshot(pid: pid_t, port: Int) -> Self? {
        let uid = geteuid()
        guard uid != 0, pid > 1, pid != getpid(), pid != getppid() else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == uid, info.pbi_ruid == uid,
              info.pbi_start_tvsec > 0, info.pbi_status != SZOMB else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return Self(port: port, pid: pid, executable: String(cString: path),
                    startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
}
