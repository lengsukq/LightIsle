import Darwin
import Foundation

/// Owns one child generation's stdin. Disk or Core stalls cannot block AppKit,
/// and a partial nonblocking write is completed before the next command.
///
/// Why `@unchecked Sendable`: wraps non-`Sendable` `FileHandle` and
/// `DispatchSourceWrite` alongside a bounded write buffer. Every read/write of
/// mutable queue state and every dispatch-source state transition (`resume`,
/// `suspend`, `cancel`) is serialized by `lock`, and `report` is only invoked
/// after releasing `lock` to prevent re-entrancy deadlocks.
final class CoreCommandWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let source: DispatchSourceWrite
    private let lock = NSLock()
    private let report: @Sendable () -> Void
    private var pending = [Data]()
    private var bytes = 0
    private var offset = 0
    private var active = false
    private var closed = false
    private var reported = false

    init(_ handle: FileHandle, report: @escaping @Sendable () -> Void) throws {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.handle = handle
        self.report = report
        source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: DispatchQueue(label: "LightIsle.CoreCommands"))
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { try? handle.close() }
    }

    func write(contentsOf data: Data) throws {
        guard !data.isEmpty else { return }
        var shouldReport = false
        let rejected = lock.withLock { () -> Bool in
            guard !closed, pending.count < 96, data.count <= 128 * 1024 - bytes else {
                shouldReport = markReportedLocked()
                return true
            }
            pending.append(data)
            bytes += data.count
            if !active {
                active = true
                source.resume()
            }
            return false
        }
        if shouldReport { report() }
        if rejected { throw CocoaError(.fileWriteUnknown) }
    }

    private func drain() {
        let shouldReport = lock.withLock { () -> Bool in
            guard !closed else { return false }
            while let data = pending.first {
                let written = data.withUnsafeBytes {
                    Darwin.write(handle.fileDescriptor, $0.baseAddress?.advanced(by: offset), data.count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN { return false }
                    let notify = markReportedLocked()
                    closeLocked()
                    return notify
                }
                if written == 0 { return false }
                offset += written
                if offset == data.count {
                    pending.removeFirst()
                    bytes -= data.count
                    offset = 0
                }
            }
            reported = false
            active = false
            source.suspend()
            return false
        }
        if shouldReport { report() }
    }

    private func markReportedLocked() -> Bool {
        guard !reported else { return false }
        reported = true
        return true
    }

    func close() {
        lock.withLock { closeLocked() }
    }

    private func closeLocked() {
        guard !closed else { return }
        closed = true
        pending.removeAll()
        source.cancel()
        if !active { source.resume() }
    }

    deinit { close() }
}
