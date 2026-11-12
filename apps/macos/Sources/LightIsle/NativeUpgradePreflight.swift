import Foundation
import SQLite3

struct NativeUpgradePreflightReport: Sendable {
    struct Database: Sendable {
        let name: String
        let status: String
    }
    let databases: [Database]
    let issues: [String]
    let warnings: [String]

    var canProceedWithManualUpgrade: Bool { issues.isEmpty }
    var summary: String {
        if !issues.isEmpty { return "检测到 \(issues.count) 项升级风险，请勿覆盖安装" }
        return "数据库基础完整性检查通过（不代表原文件已备份）"
    }
}

/// Read-only upgrade preparation; this is NOT an updater and does not change
/// database schemas, WAL files, backups, or shared NAS originals.
enum NativeUpgradePreflight {
    static func inspect(_ directory: URL) -> NativeUpgradePreflightReport {
        var issues: [String] = []
        var results: [NativeUpgradePreflightReport.Database] = []
        var warnings = ["运行中的数据库检查仅用于预检；正式升级前应退出旧 App 并验证独立备份。"]
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue,
              !isSymlink(directory) else {
            return .init(databases: [], issues: ["未找到安全的 LightIsle 私有数据库目录"], warnings: warnings)
        }
        var candidates: [(label: String, url: URL)]
        do {
            candidates = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: [])
                .filter { $0.pathExtension == "sqlite" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { ($0.lastPathComponent, $0) }
        } catch {
            return .init(databases: [], issues: ["无法读取数据库目录"], warnings: warnings)
        }
        let automationDir = directory.appendingPathComponent("automation", isDirectory: true)
        var autoIsDir: ObjCBool = false
        if fm.fileExists(atPath: automationDir.path, isDirectory: &autoIsDir) || isSymlink(automationDir) {
            if isSymlink(automationDir) || !autoIsDir.boolValue {
                issues.append("automation：不是安全的子目录")
            } else {
                let autoDB = automationDir.appendingPathComponent("automation.sqlite")
                if fm.fileExists(atPath: autoDB.path) || isSymlink(autoDB) {
                    candidates.append(("automation/automation.sqlite", autoDB))
                }
            }
        }
        guard !candidates.isEmpty, candidates.count <= 64 else {
            return .init(databases: [], issues: ["数据库缺失或数量异常"], warnings: warnings)
        }
        if !candidates.contains(where: { $0.label == "accounts.sqlite" }) {
            issues.append("缺少账号数据库 accounts.sqlite")
        }
        for item in candidates {
            let name = item.label
            let url = item.url
            guard !isSymlink(url), (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                issues.append("\(name)：不是安全的普通文件")
                results.append(.init(name: name, status: "路径异常"))
                continue
            }
            var db: OpaquePointer?
            let result = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
            guard result == SQLITE_OK, let db else {
                if db != nil { sqlite3_close(db) }
                issues.append("\(name)：无法只读打开")
                results.append(.init(name: name, status: "无法读取"))
                continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 1500)
            var statement: OpaquePointer?
            let prepared = sqlite3_prepare_v2(db, "PRAGMA quick_check(1)", -1, &statement, nil)
            let good = prepared == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW &&
                sqlite3_column_text(statement, 0).map { String(cString: $0) == "ok" } == true
            if statement != nil { sqlite3_finalize(statement) }
            if good {
                results.append(.init(name: name, status: "基础检查通过"))
            } else {
                issues.append("\(name)：完整性检查未通过（或数据库正在锁定）")
                results.append(.init(name: name, status: "未通过"))
            }
            if fm.fileExists(atPath: url.path + "-wal") {
                warnings.append("\(name) 存在 WAL：升级前请正常关闭旧 App，不要手工删除日志文件。")
            }
        }
        return .init(databases: results, issues: issues, warnings: warnings)
    }
    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
