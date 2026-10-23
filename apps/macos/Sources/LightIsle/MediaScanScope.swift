import Foundation

/// Converts FSEvents paths to safe relative parent directories for Core's
/// scoped scanner. A nil result means the caller must request a full reconciliation.
enum MediaScanScope {
    static func directories(for paths: [String]?, under root: String) -> [String]? {
        guard let paths else { return nil }
        var directories = Set<String>()
        for raw in paths {
            let absolute = (raw as NSString).standardizingPath
            guard absolute.hasPrefix(root + "/") else { return nil }
            let parent = (absolute as NSString).deletingLastPathComponent
            let relative = parent == root ? "." : String(parent.dropFirst(root.count + 1))
            // Backslash is a valid macOS filename character, but Core rejects
            // it as a path separator for cross-platform traversal safety.
            // Fall back to a trusted full scan instead of dropping this event.
            guard relative.utf8.count <= 1024,
                  !relative.contains("\n"), !relative.contains("\r"), !relative.contains("\\") else {
                return nil
            }
            directories.insert(relative)
            if directories.count > 32 { return nil }
        }
        return directories.sorted()
    }
}
