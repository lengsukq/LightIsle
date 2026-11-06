import Foundation

@MainActor
struct AdditionalDirectoryWatcher {
    let generation: UInt64
    let path: String
    let watcher: DirectoryChangeWatcher
}

@MainActor
extension AppModel {
    /// Additional registered disks have their own root-bound event stream.
    /// A root disappearing, changing generation or becoming the default
    /// invalidates both its watcher and any queued request.
    func updateAdditionalDirectoryWatchers(_ roots: [NativeSharedRoot]) {
        let eligible = Dictionary(uniqueKeysWithValues: roots.filter {
            $0.online && !$0.pending && $0.isDefault != true && $0.path.hasPrefix("/")
        }.map { ($0.rootID, $0) })
        for id in Array(additionalDirectoryWatchers.keys) {
            guard let existing = additionalDirectoryWatchers[id] else { continue }
            if let root = eligible[id], root.generation == existing.generation, root.path == existing.path {
                continue
            }
            existing.watcher.stop()
            additionalDirectoryWatchers.removeValue(forKey: id)
            additionalScanTasks.removeValue(forKey: id)?.cancel()
            additionalLastScanRequest.removeValue(forKey: id)
            additionalPendingDirectories.removeValue(forKey: id)
        }
        for (id, root) in eligible where additionalDirectoryWatchers[id] == nil {
            guard let watcher = DirectoryChangeWatcher(path: root.path, onChange: { [weak self] paths, full in
                let dirs = full ? nil : MediaScanScope.directories(for: paths, under: root.path)
                self?.scheduleAdditionalRootRefresh(id: id, generation: root.generation, path: root.path, dirs: dirs)
            }) else { continue }
            additionalDirectoryWatchers[id] = AdditionalDirectoryWatcher(
                generation: root.generation, path: root.path, watcher: watcher
            )
            // FSEvents starts at the current point and cannot cover changes
            // made before launch or while this particular disk was offline.
            scheduleAdditionalRootRefresh(id: id, generation: root.generation, path: root.path, dirs: nil)
        }
    }

    private func scheduleAdditionalRootRefresh(id: String, generation: UInt64, path: String, dirs: [String]?) {
        guard state == .online else { return }
        var pending = additionalPendingDirectories[id] ?? []
        if let dirs, !dirs.isEmpty, !pending.contains(".") {
            pending.formUnion(dirs)
        } else if dirs == nil || dirs?.isEmpty == true {
            pending = ["."]
        }
        if pending.count > 32 || pending.contains(".") { pending = ["."] }
        additionalPendingDirectories[id] = pending
        guard additionalScanTasks[id] == nil else { return }
        let elapsed = Date().timeIntervalSince(additionalLastScanRequest[id] ?? .distantPast)
        let delay = max(2.0, 60.0 - elapsed)
        additionalScanTasks[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.additionalScanTasks.removeValue(forKey: id)
            guard !Task.isCancelled, self.state == .online,
                  let current = self.additionalDirectoryWatchers[id],
                  current.generation == generation, current.path == path,
                  let pipe = self.inputPipe else { return }
            let dirs = Array(self.additionalPendingDirectories.removeValue(forKey: id) ?? ["."]).sorted()
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
                try pipe.fileHandleForWriting.write(contentsOf: Data("index root \(encoded)\n".utf8))
                self.additionalLastScanRequest[id] = Date()
            } catch {
                // Periodic reconciliation is the fallback if the Core pipe
                // closes before this event can be handed off.
            }
        }
    }
}
