import Foundation

@main
struct MediaScanScopeCheck {
    static func main() {
        let root = "/Volumes/TestShare/SharedFiles"
        precondition(
            MediaScanScope.directories(for: [root + "/Albums/2026/photo.jpg"], under: root) == ["Albums/2026"],
            "ordinary changed files should scan only their parent directory"
        )
        precondition(
            MediaScanScope.directories(for: [root + "/photo.jpg"], under: root) == ["."],
            "a top-level event should request the share root"
        )
        precondition(
            MediaScanScope.directories(for: [root + "/Albums\\2026/photo.jpg"], under: root) == nil,
            "a legal macOS backslash filename must fall back to a full scan"
        )
        precondition(
            MediaScanScope.directories(for: [root + "/../Outside/photo.jpg"], under: root) == nil,
            "a path escaping the watched root must fall back to a full scan"
        )
        print("PASS: FSEvents scopes stay targeted when safe and fall back for backslash or escaped paths")
    }
}
