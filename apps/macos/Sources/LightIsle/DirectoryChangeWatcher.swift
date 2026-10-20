import CoreServices
import Foundation

/// Lightweight recursive filesystem event source. Owned by the Mac App and
/// released with its Go child; no persistent background watcher is installed.
@MainActor
final class DirectoryChangeWatcher {
    private var stream: FSEventStreamRef?
    private let callback: () -> Void

    init?(path: String, onChange: @escaping () -> Void) {
        callback = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        let handler: FSEventStreamCallback = { _, pointer, _, _, _, _ in
            guard let pointer else { return }
            let watcher = Unmanaged<DirectoryChangeWatcher>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in watcher.callback() }
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
        guard let events = stream else { return }
        stream = nil
        FSEventStreamStop(events)
        FSEventStreamInvalidate(events)
        FSEventStreamRelease(events)
    }
}
