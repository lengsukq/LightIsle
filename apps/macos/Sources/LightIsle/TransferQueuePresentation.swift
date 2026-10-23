import Foundation

struct NativeTransferTask: Decodable, Identifiable {
    let id: String
    let source: String
    let destination: String
    let mode: String
    let state: String
    let phase: String
    let completedBytes: Int64
    let totalBytes: Int64
    let error: String?
    let createdAt: Int64
    let updatedAt: Int64
    let publishedPath: String?
    let trashId: String?

    var isActive: Bool { state == "queued" || state == "running" }
    var canRetry: Bool { ["failed", "cancelled", "interrupted"].contains(state) }
    var progress: Double { totalBytes > 0 ? min(1, max(0, Double(completedBytes) / Double(totalBytes))) : 0 }
    var operationLabel: String { mode == "move" ? "安全移动" : "安全复制" }
    var stateLabel: String {
        switch state {
        case "queued": return "等待执行"
        case "running":
            switch phase {
            case "verifying": return "正在校验副本"
            case "publishing": return "正在发布目标"
            case "trashing", "moving_source": return "正在将源文件移入回收站"
            case "scanning", "checking": return "正在核对目录和磁盘"
            default: return "正在复制"
            }
        case "completed": return "已完成"
        case "cancelled": return "已取消"
        case "interrupted": return "上次运行已中断"
        case "failed": return "未完成"
        default: return "状态待核对"
        }
    }
}

struct NativeTransferPage: Decodable {
    let schemaVersion: Int
    let tasks: [NativeTransferTask]
    let nextCursor: String
    let activeCount: Int
    let totalCount: Int
    let requestedCursor: String
    let runningTask: NativeTransferTask?
}

struct NativeTransferFailure: Decodable { let operation: String; let error: String }
struct NativeTransferChange: Decodable { let operation: String; let id: String }

enum TransferQueuePresentation {
    static func decode<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        guard raw.utf8.count <= 360_000 else { return nil }
        var normalized = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized), data.count <= 256 * 1024 else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func errorMessage(_ error: String) -> String {
        if error.contains("queue_full") || error.contains("queue_limit") {
            return "传输记录已满。核对已结束的任务后，可移除相应记录再添加任务。"
        }
        if error.contains("identity") || error.contains("volume") || error.contains("root_changed") {
            return "任务绑定的磁盘、共享目录或源文件已变化。请重新连接原磁盘并核对文件，再重试。"
        }
        if error.contains("already_exists") { return "目标已有同名文件，未覆盖。请核对已有副本或重新选择目标目录。" }
        if error == "transfer_enqueue_busy" { return "正在核对上一个任务的源目录，请稍后再添加。" }
        if error == "transfer_queue_unavailable" { return "传输记录暂不可用，原有记录和文件均保留。请检查本机日志。" }
        if error.contains("context canceled") { return "操作已停止；请核对目标副本和回收站，已发布的文件不会自动撤回。" }
        return error
    }
}
