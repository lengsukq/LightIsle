import Foundation

// Display-only mount association and conservative shortcuts. The Go Core
// remains the sole authority for selecting a directory and verifying its
// physical volume identity.
enum StorageVolumeSelection {
    static func canInspectExternalVolume(mount: String) -> Bool {
        guard mount.hasPrefix("/Volumes/") else { return false }
        let name = String(mount.dropFirst("/Volumes/".count))
        return !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") &&
            URL(fileURLWithPath: mount).standardizedFileURL.path == mount
    }
    static func contains(_ path: String?, in mount: String) -> Bool {
        guard let path, path.hasPrefix("/"), mount.hasPrefix("/") else { return false }
        let selected = URL(fileURLWithPath: path).standardizedFileURL.path
        let base = URL(fileURLWithPath: mount).standardizedFileURL.path
        return base == "/" ? selected.hasPrefix("/") :
            (selected == base || selected.hasPrefix(base + "/"))
    }

    static func matchingMount(for path: String?, mounts: [String]) -> String? {
        // macOS can report a temporarily unmounted external drive while the
        // root filesystem remains visible. Never label its old /Volumes/...
        // path as belonging to the system disk.
        if let path, path.hasPrefix("/Volumes/") {
            return mounts.filter { $0 != "/" && contains(path, in: $0) }
                .max { $0.count < $1.count }
        }
        return mounts.filter { contains(path, in: $0) }.max { $0.count < $1.count }
    }

    // Only a named, writable mounted volume gets a direct disk shortcut.
    // The system disk and arbitrary filesystem paths retain the original
    // explicit folder picker but are never offered as one-click destinations.
    static func canChooseOnVolume(mount: String, readOnly: Bool) -> Bool {
        !readOnly && canInspectExternalVolume(mount: mount)
    }
}
