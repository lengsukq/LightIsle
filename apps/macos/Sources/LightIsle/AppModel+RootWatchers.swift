import Foundation

@MainActor
struct RootDirectoryWatcher {
    let generation: UInt64
    let path: String
    let watcher: DirectoryChangeWatcher
}

@MainActor
extension AppModel {
    /// Every online root uses the same scoped watcher. A change of default
    /// keeps an existing physical watch and its queued directories.
    func updateRootDirectoryWatchers(_ roots: [NativeSharedRoot]) {
        let initial = !rootWatchersInitialized
        rootWatchersInitialized = true
        let eligible = Dictionary(uniqueKeysWithValues: roots.filter {
            $0.online && !$0.pending && $0.path.hasPrefix("/")
        }.map { ($0.rootID, $0) })
        for id in Array(rootDirectoryWatchers.keys) {
            guard let existing = rootDirectoryWatchers[id] else { continue }
            if let root = eligible[id], root.generation == existing.generation, root.path == existing.path {
                continue
            }
            existing.watcher.stop()
            rootDirectoryWatchers.removeValue(forKey: id)
            rootScanTasks.removeValue(forKey: id)?.cancel()
            rootLastScanRequest.removeValue(forKey: id)
            rootPendingDirectories.removeValue(forKey: id)
        }
        for (id, root) in eligible where rootDirectoryWatchers[id] == nil {
            guard let watcher = DirectoryChangeWatcher(path: root.path, onChange: { [weak self] paths, full in
                let dirs = full ? nil : MediaScanScope.directories(for: paths, under: root.path)
                if dirs?.isEmpty == true { return }
                self?.scheduleRootRefresh(id: id, generation: root.generation, path: root.path, dirs: dirs)
            }) else { continue }
            rootDirectoryWatchers[id] = RootDirectoryWatcher(
                generation: root.generation, path: root.path, watcher: watcher
            )
            // Core runs one serial startup pass. A newly attached or
            // reconnected disk needs a catch-up after that initial snapshot.
            if !initial {
                scheduleRootRefresh(id: id, generation: root.generation, path: root.path, dirs: nil)
            }
        }
    }

    private func scheduleRootRefresh(id: String, generation: UInt64, path: String, dirs: [String]?) {
        guard state == .online else { return }
        var pending = rootPendingDirectories[id] ?? []
        if let dirs, !dirs.isEmpty, !pending.contains(".") {
            pending.formUnion(dirs)
        } else if dirs == nil || dirs?.isEmpty == true {
            pending = ["."]
        }
        if pending.count > 32 || pending.contains(".") { pending = ["."] }
        rootPendingDirectories[id] = pending
        guard rootScanTasks[id] == nil else { return }
        let elapsed = Date().timeIntervalSince(rootLastScanRequest[id] ?? .distantPast)
        let delay = max(2.0, 60.0 - elapsed)
        rootScanTasks[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.rootScanTasks.removeValue(forKey: id)
            guard !Task.isCancelled, self.state == .online,
                  let current = self.rootDirectoryWatchers[id],
                  current.generation == generation, current.path == path,
                  let pipe = self.coreCommands else { return }
            let dirs = Array(self.rootPendingDirectories.removeValue(forKey: id) ?? ["."]).sorted()
            var request: [String: Any] = ["rootID": id, "generation": generation, "dirs": dirs]
            guard var payload = try? JSONSerialization.data(withJSONObject: request) else { return }
            if payload.count > 8000 {
                request["dirs"] = ["."]
                guard let fullPayload = try? JSONSerialization.data(withJSONObject: request) else { return }
                payload = fullPayload
            }
            let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            do {
                try pipe.write(contentsOf: Data("index root \(encoded)\n".utf8))
                self.rootLastScanRequest[id] = Date()
            } catch {
                // Periodic reconciliation is the fallback if the Core pipe
                // closes before this event can be handed off.
            }
        }
    }
}
