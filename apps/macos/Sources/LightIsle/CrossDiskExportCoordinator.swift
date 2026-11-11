import AppKit
import Foundation

/// The native owner chooses a source and destination; Core independently
/// validates the physical disks, filesystem rights, journal and final publish.
/// Browser and member APIs never receive this privileged transfer request.
struct CrossDiskExportPlan: Encodable {
    let source: String
    let destination: String
    let mode: String

    /// The selected path must resolve to a non-root descendant of the shared
    /// folder. A symlink into another disk must never pass this check.
    static func relativeSource(sharedRoot: URL, selected: URL) -> String? {
        let root = sharedRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let path = selected.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The target must not be inside the active shared folder, including
    /// symlinks pointing back to it. Core still verifies distinct volumes.
    static func destinationOutsideShare(sharedRoot: URL, destination: URL) -> Bool {
        let root = sharedRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let target = destination.standardizedFileURL.resolvingSymlinksInPath().path
        guard root != "/" else { return false }
        return target != root && !target.hasPrefix(root + "/")
    }

    var ipcLine: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return "export start " + data.base64URLEncodedString + "\n"
    }
}

enum CrossDiskExportChoice {
    case cancelled
    case rejected(String)
    case selected(CrossDiskExportPlan)
}

/// Presentation and pure planning are kept out of AppModel so state handling
/// has one owner. Alerts are shown only by the interactive macOS owner UI.
enum CrossDiskExportCoordinator {
    @MainActor
    static func choose(sharedFolderPath: String) -> CrossDiskExportChoice {
        let share = URL(fileURLWithPath: sharedFolderPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()

        let sourcePanel = NSOpenPanel()
        sourcePanel.directoryURL = share
        sourcePanel.canChooseDirectories = true
        sourcePanel.canChooseFiles = true
        sourcePanel.allowsMultipleSelection = false
        sourcePanel.canCreateDirectories = false
        sourcePanel.prompt = "选择复制来源"
        sourcePanel.message = "选择共享目录内的文件或文件夹；源文件不会移动或删除。"
        guard sourcePanel.runModal() == .OK, let sourceURL = sourcePanel.url else {
            return .cancelled
        }
        guard let relative = CrossDiskExportPlan.relativeSource(
            sharedRoot: share, selected: sourceURL
        ) else {
            return .rejected("只能复制当前共享目录里的文件或子文件夹，不能通过符号链接访问其他位置。")
        }

        let destinationPanel = NSOpenPanel()
        destinationPanel.canChooseDirectories = true
        destinationPanel.canChooseFiles = false
        destinationPanel.allowsMultipleSelection = false
        destinationPanel.canCreateDirectories = true
        destinationPanel.prompt = "复制到此目录"
        destinationPanel.message = "先复制并校验 SHA-256，再原子发布。目标同名文件不会被覆盖，不能选择共享目录内部。"
        guard destinationPanel.runModal() == .OK,
              let destinationURL = destinationPanel.url else {
            return .cancelled
        }
        guard CrossDiskExportPlan.destinationOutsideShare(
            sharedRoot: share, destination: destinationURL
        ) else {
            return .rejected("复制目标不能位于当前共享目录内或通过符号链接指向当前共享目录。")
        }

        let modeAlert = NSAlert()
        modeAlert.messageText = "选择跨磁盘操作"
        modeAlert.informativeText = "安全复制：源文件保持原样。\n安全移动：仅支持普通文件，先完整复制、SHA-256 校验并持久记录，成功后才把源文件移至轻屿回收站；目标永不覆盖已有文件。发生错误或停电可能保留源与目标两个副本，不会主动销毁源数据。"
        modeAlert.alertStyle = .warning
        modeAlert.addButton(withTitle: "安全复制")
        modeAlert.addButton(withTitle: "复制后移入回收站")
        modeAlert.addButton(withTitle: "取消")
        let pickedMode = modeAlert.runModal()
        guard pickedMode != .alertThirdButtonReturn else { return .cancelled }
        let mode = pickedMode == .alertSecondButtonReturn ? "move" : "copy"
        if mode == "move" {
            let path = sourceURL.standardizedFileURL.resolvingSymlinksInPath().path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            guard attrs?[.type] as? FileAttributeType == .typeRegular else {
                return .rejected("跨盘安全移动仅支持单个普通文件；文件夹请先安全复制。")
            }
        }
        return .selected(CrossDiskExportPlan(
            source: relative,
            destination: destinationURL.standardizedFileURL.resolvingSymlinksInPath().path,
            mode: mode
        ))
    }
}
