import CoreServices
import Foundation

/// Lightweight recursive filesystem event source. Owned by the Mac App and
/// released with its Go child; no persistent background watcher is installed.
@MainActor
final class DirectoryChangeWatcher {
    private var stream: FSEventStreamRef?
    private let callback: ([String]?, Bool) -> Void
    private var active = true

    init?(path: String, onChange: @escaping ([String]?, Bool) -> Void) {
        callback = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        let handler: FSEventStreamCallback = { _, pointer, count, eventPaths, flags, _ in
            guard let pointer else { return }
            let watcher = Unmanaged<DirectoryChangeWatcher>.fromOpaque(pointer).takeUnretainedValue()
            // A dropped/ambiguous event stream needs a full reconciliation.
            // Fail closed instead of guessing which subdirectory changed.
            let rescanFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs |
                kFSEventStreamEventFlagUserDropped |
                kFSEventStreamEventFlagKernelDropped |
                kFSEventStreamEventFlagRootChanged |
                kFSEventStreamEventFlagMount |
                kFSEventStreamEventFlagUnmount
            )
            var needsFull = count > 64
            for i in 0..<min(Int(count), 65) {
                if flags[i] & rescanFlags != 0 { needsFull = true; break }
            }
            var changedPaths: [String]? = nil
            if !needsFull {
                let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                changedPaths = (array as NSArray) as? [String]
                if changedPaths?.count != Int(count) { needsFull = true }
            }
            // A queued callback must not reach the next Core/root after
            // this watcher has been invalidated by a disk disconnect.
            Task { @MainActor [weak watcher] in
                guard let watcher, watcher.active else { return }
                watcher.callback(changedPaths, needsFull)
            }
        }
        guard let events = FSEventStreamCreate(
            kCFAllocatorDefault, handler, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.5, flags
        ) else { return nil }
        stream = events
        FSEventStreamSetDispatchQueue(events, DispatchQueue.main)
        guard FSEventStreamStart(events) else {
            FSEventStreamInvalidate(events)
            FSEventStreamRelease(events)
            stream = nil
            return nil
        }
    }

    func stop() {
        active = false
        guard let events = stream else { return }
        stream = nil
        FSEventStreamStop(events)
        FSEventStreamInvalidate(events)
        FSEventStreamRelease(events)
    }
}
