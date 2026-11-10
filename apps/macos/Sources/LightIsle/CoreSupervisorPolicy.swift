import Foundation

struct CoreSupervisorPolicy {
    static let portInUseExitCode: Int32 = 73
    static let delays = [2, 10, 30]
    static let probeInterval: Double = 15
    static let failedProbeLimit = 3

    private(set) var attempts = 0
    private var readyAt: TimeInterval?
    private var failedProbes = 0

    mutating func markReady(at uptime: TimeInterval) {
        readyAt = uptime
        failedProbes = 0
    }

    mutating func recordProbe(healthy: Bool) -> Bool {
        failedProbes = healthy ? 0 : failedProbes + 1
        return failedProbes >= Self.failedProbeLimit
    }

    mutating func nextRetry(at uptime: TimeInterval, startupBlocked: Bool = false) -> Int? {
        let wasReady = readyAt != nil
        if let readyAt, uptime - readyAt >= 300 { attempts = 0 }
        readyAt = nil
        failedProbes = 0
        guard !startupBlocked, wasReady || attempts > 0, attempts < Self.delays.count else { return nil }
        let delay = Self.delays[attempts]
        attempts += 1
        return delay
    }

    // These exit codes describe conditions that need an owner to intervene.
    // A signal exit is never interpreted as an application exit code.
    static func startupBlocker(exitCode: Int32) -> String? {
        switch exitCode {
        case 70: return "轻屿无法打开账号或存储登记。请检查 Mac 的应用数据目录和权限。"
        case 71: return "轻屿的数据目录正在使用。请结束另一份轻屿或等待数据库恢复结束。"
        case 72: return "上一次数据库恢复尚未完成。请在此页修复中断的恢复。"
        case portInUseExitCode: return "本机服务端口已被占用。"
        case 74: return "恢复后的账号会话无法安全清除。请检查数据库权限和恢复状态。"
        case 76: return "本机服务无法监听。请检查 Mac 的网络和系统权限后重试。"
        default: return nil
        }
    }
}
