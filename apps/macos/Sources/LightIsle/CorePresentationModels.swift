import Foundation

// Read-only, typed Core status models shared by the native management UI.
// Kept separate from AppModel's process and IPC lifecycle.
struct HostVolume: Decodable, Identifiable, Equatable {
    let name: String
    let mount: String
    let device: String
    let filesystem: String
    let total: UInt64
    let free: UInt64
    let readOnly: Bool
    var id: String { mount }
}
struct NASBackupSchedule: Decodable, Equatable {
    let backupType: String?
    let enabled: Bool
    let everyHours: Int
    let destination: String?
    let lastAttempt: Int64
    let nextRun: Int64
    let lastError: String?
    let planID: String?
    let retentionCount: Int?
    let destinationVolumeUUID: String?
    let destinationDirectoryID: String?
    let destinationIdentityStatus: String?
}

struct NASBackupStatus: Decodable, Equatable {
    let running: Bool
    let operation: String
    let files: Int
    let bytes: Int64
    let lastError: String?
    let lastSnapshot: String?
    let restoredMetadata: String?
    let lastDone: Int64?
    let retentionError: String?
    let retentionRemoved: Int?
}

struct NASBackupSnapshot: Decodable, Identifiable, Equatable {
    let name: String
    let path: String
    let version: String
    let backupType: String?
    let createdAt: Int64
    let sizeBytes: Int64
    let integrity: String
    let integrityDetail: String?
    var id: String { path }
}

struct NASBackupInventory: Decodable, Equatable {
    let destination: String
    let snapshots: [NASBackupSnapshot]
    let truncated: Bool
    let scannedEntries: Int
}

struct HostProcess: Decodable, Identifiable, Equatable {
    let pid: Int
    let name: String
    let cpuPercent: Double?
    let rssBytes: UInt64?
    var id: Int { pid }
}

struct HostMetrics: Decodable, Equatable {
    let hostname: String
    let architecture: String
    let cpuCount: Int
    let cpuPercent: Double?
    let memoryTotal: UInt64
    let memoryUsed: UInt64
    let diskTotal: UInt64
    let diskFree: UInt64
    let volumes: [HostVolume]?
    let networkDownBps: Double?
    let networkUpBps: Double?
    let diskIo: [HostDiskIO]?
    let corePid: Int?
    let coreRssBytes: UInt64?
    let processes: [HostProcess]?
    let processesAvailable: Bool?
}

struct HostDiskIO: Decodable, Equatable {
    let device: String
    let readBps: Double?
    let writeBps: Double?
}

struct DiskHealthReport: Decodable, Equatable {
    let device: String
    let source: String
    let reason: String?
    let model: String?
    let serial: String?
    let firmware: String?
    let temperature: Int?
    let passed: Bool?
    let powerOnHours: Int?
    let lifeUsed: Int?
}

struct StorageThreshold: Codable, Equatable {
    var freeMiB: Int
    var percent: Int
}

struct MetricHistoryPoint: Identifiable {
    let id = UUID()
    let time: Date
    let cpu: Double
    let memory: Double
    let download: Double
    let upload: Double
}

/// Shared main-actor formatter cache so SwiftUI body passes avoid allocating
/// temporary ByteCountFormatter or DateFormatter instances per render.
@MainActor
enum IsleFormatters {
    private static let fileBytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let binaryBytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }()

    private static let memoryBytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let abbreviatedDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let timeHMSFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    static func fileSize(_ bytes: Int64) -> String {
        fileBytes.string(fromByteCount: bytes)
    }

    static func fileSize(_ bytes: UInt64) -> String {
        fileBytes.string(fromByteCount: Int64(clamping: bytes))
    }

    static func binarySize(_ bytes: Int64) -> String {
        binaryBytes.string(fromByteCount: bytes)
    }

    static func memorySize(_ bytes: Int64) -> String {
        memoryBytes.string(fromByteCount: bytes)
    }

    static func dateTime(unixSeconds: Int64) -> String {
        dateTimeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }

    static func abbreviatedDateTime(unixSeconds: Int64) -> String {
        abbreviatedDateTimeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }

    static func timeHMS(_ date: Date) -> String {
        timeHMSFormatter.string(from: date)
    }
}

