import SwiftUI
import Foundation
import ServiceManagement

enum CoreState: Equatable {
    case offline
    case starting
    case online
    case stopping
    case error(String)

    var label: String {
        switch self {
        case .offline: return "未运行"
        case .starting: return "正在启动"
        case .online: return "正在运行"
        case .stopping: return "正在停止"
        case .error: return "运行异常"
        }
    }
}
struct ManagedDisk: Decodable, Identifiable {
    let id: String
    let name: String
    let mount: String
    let parent: String
    let filesystem: String
    let protocolName: String
    let smart: String
    let total: UInt64
    let free: UInt64
    let readOnly: Bool
    let mounted: Bool
    let external: Bool
    let identity: String
    enum CodingKeys: String, CodingKey {
        case id, name, mount, parent, filesystem, smart, total, free, readOnly, mounted, external, identity
        case protocolName = "protocol"
    }
}

struct FileTransferReceipt: Decodable, Identifiable {
    let id: String
    let source: String
    let destination: String
    let phase: String
    let error: String?
    let startedAt: Int64
    let updatedAt: Int64
    let sourceSize: Int64
    let trashId: String?

    var statusDescription: String {
        switch phase {
        case "source_in_trash": return "已完成 · 源文件在回收站"
        case "published": return "目标已发布 · 请核对源文件位置"
        case "copy_incomplete": return "复制中断 · 源文件保留"
        case "copy_published_unconfirmed": return "目标已出现，落盘未确认 · 源文件保留"
        case "source_changed_restored": return "校验未通过 · 源文件已还原，请核对两个副本"
        case "source_trash_unresolved": return "移动未完成 · 待核对的文件保存在回收站"
        case "source_move_uncertain": return "源文件位置待核对 · 请保留目标与回收站副本"
        case "source_trash_failed": return "移入回收站失败 · 请核对源文件与目标"
        default: return "尚未完成 · 请核对源文件与目标"
        }
    }
}

struct NASMetadataRollbackTransaction: Decodable, Identifiable {
    let id: String
    let state: String
    let canRollback: Bool
    let reason: String?
    let activatedAt: Int64
    let fileCount: Int
}

struct NASMetadataRollbackInventory: Decodable {
    let schemaVersion: Int
    let operation: String
    let transactions: [NASMetadataRollbackTransaction]
    let truncated: Bool
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    var isPresentationPreview: Bool {
        #if DEBUG
        return Bundle.main.object(forInfoDictionaryKey: "LightIsleDesignPreview") as? Bool == true
        #else
        return false
        #endif
    }
    let rootManagement = NativeRootsModel(enabled: true)
    let personalSpaces = NativeSpacesModel()

    @Published var state: CoreState = .offline {
        didSet {
            guard !isPresentationPreview else { return }
            servicePresence.updateSleepPolicy(serviceOnline: state == .online, keepAwake: keepAwakeWhileServing)
            servicePresence.updateBonjour(serviceOnline: state == .online, remoteAddress: remoteAddress)
            if case .error = state {
                notifyImportantEvent("core-failure", title: "LightIsle 服务异常", message: "NAS 核心未能正常运行，请在 Mac 上打开轻屿检查。")
            } else if state == .online {
                nativeAlertCoordinator.clear(key: "core-failure")
            }
        }
    }
    var navigationRequest: ((SidebarPage) -> Void)?
    var storageDetailNavigationRequest: ((StorageDetail) -> Void)?
    func navigate(to page: SidebarPage) {
        if let navigationRequest { navigationRequest(page) } else { selectedSidebarPage = page }
    }
    func navigateToStorageDetail(_ detail: StorageDetail) {
        if let storageDetailNavigationRequest {
            storageDetailNavigationRequest(detail)
        } else {
            selectedSidebarPage = .storage
        }
    }
    @Published var selectedSidebarPage: SidebarPage = .overview
    @Published var activeAlerts: [CorePersistentAlert] = []
    @Published var lastMetricsAt: Date?
    @Published var administratorSaveSucceeded = false
    @Published var administratorResetSucceeded = false
    var diagnosticsVisible = false

    @Published var reindexRequestMessage: String?

    @Published var keepAwakeWhileServing = UserDefaults.standard.bool(forKey: "lightisle.keepAwakeWhileServing")
    @Published var isLightweightMode = false
    @Published var autoLightweightOnLock = LightweightModePolicy.autoOnLock()
    @Published var loginItemError: String?
    @Published var nativeAlertsEnabled = UserDefaults.standard.bool(forKey: "lightisle.nativeAlertsEnabled")
    @Published var nativeAlertError: String?
    var alertAuthorizationPending = false
    let nativeAlertCoordinator = NativeAlertCoordinator()
    var lastAlertPollAt = Date.distantPast

    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    var visibleManagementWindows = Set<ObjectIdentifier>()
    var samplesManagementUI: Bool {
        !isLightweightMode && !visibleManagementWindows.isEmpty
    }

    @Published var endpoint: URL?
    @Published var details: String = "LightIsle 应用负责管理内置服务的完整生命周期。"
    @Published var remoteAddress: String? {
        didSet { if !isPresentationPreview { servicePresence.updateBonjour(serviceOnline: state == .online, remoteAddress: remoteAddress) } }
    }
    @Published var bonjourStatus = "未广播（局域网监听未开启）"
    lazy var servicePresence: NativeServicePresenceCoordinator = {
        let coordinator = NativeServicePresenceCoordinator()
        coordinator.onBonjourStatusChange = { [weak self] status in self?.bonjourStatus = status }
        return coordinator
    }()
    @Published var remoteFingerprint: String?
    @Published var remoteError: String?
    @Published var remoteBusy = false
    var remoteDeadline: Task<Void, Never>?
    @Published var sharedFolderName: String = "SharedFiles"
    @Published var sharedFolderPath: String? {
        didSet {
            if oldValue != sharedFolderPath {
                invalidateTimeMachineDiagnostics()
            }
        }
    }
    @Published var sharedFolderError: String?
    @Published var offlineSharedFolderPath: String?
    @Published var offlineCleanupPending = false
    @Published var offlineCleanupMessage: String?
    @Published var storageSelectionMessage: String?
    @Published var storageSelectionPending = false
    var pendingStorageTarget: String?
    var previousStorageRoot: String?
    var legacyAccessRevokedForPendingRoot: Bool?
    var storageSelectionDeadline: Task<Void, Never>?

    @Published var exportRunning = false
    @Published var exportMessage: String?
    @Published var transferHistory: [FileTransferReceipt] = []
    var activeExportMode = "copy"
    @Published var isConfigured: Bool?
    @Published var initializationError: String?
    @Published var initializing = false
    @Published var metrics: HostMetrics?
    @Published var metricHistory: [MetricHistoryPoint] = []
    @Published var backupStatus: NASBackupStatus?
    @Published var backupError: String?
    @Published var backupInventory: NASBackupInventory?
    @Published var backupInventoryLoading = false
    @Published var activatingMetadata = false
    @Published var metadataActivationMessage: String?
    @Published var metadataPreview: NASMetadataRecoveryPreview?
    @Published var metadataPreviewStageName: String?
    @Published var metadataPreviewLoading = false
    @Published var metadataRollbacks: NASMetadataRollbackInventory?
    @Published var metadataRollbacksLoading = false
    @Published var metadataRollbackError: String?
    @Published var upgradePreflight: NativeUpgradePreflightReport?
    @Published var upgradePreflightChecking = false
    var upgradePreflightRequest: UUID?

    @Published var smbListening: Bool?
    @Published var smbState: NativeSMBStatus?
    @Published var smbBusy = false
    @Published var smbError: String?
    @Published var smbNotice: String?
    @Published var timeMachineDiagnostics: TimeMachineDiagnostics?
    @Published var timeMachineChecking = false
    var timeMachineDiagnosticsGeneration: UInt64 = 0

    @Published var backupSchedule: NASBackupSchedule?
    @Published var portError: String?
    @Published var thumbnailCacheError: String?
    @Published var webOpenError: String?
    @Published var vaultMessage: String?
    @Published var unlockedAdminCredentials: AdminCredentials?
    @Published var verifyingAdmin = false
    @Published var resettingAdmin = false
    @Published var resetAdminMessage: String?
    @Published var firstAdminUsername: String?
    var pendingAdminCredentials: AdminCredentials?
    var rootDirectoryWatchers: [String: RootDirectoryWatcher] = [:]
    var rootScanTasks: [String: Task<Void, Never>] = [:]
    var rootLastScanRequest: [String: Date] = [:]
    var rootPendingDirectories: [String: Set<String>] = [:]
    var rootWatchersInitialized = false

    static let defaultLocalPort = 16666
    var preferredLocalPort: Int {
        let value = UserDefaults.standard.integer(forKey: "lightisle.localPort")
        return (1024...65535).contains(value) ? value : Self.defaultLocalPort
    }

    static let thumbnailCacheOptions: [Int] = [256, 512, 1024, 2048, 4096, 8192]
    static let defaultThumbnailCacheMiB = 1024

    var preferredThumbnailCacheMiB: Int {
        let value = UserDefaults.standard.integer(forKey: "lightisle.thumbnailCacheMiB")
        return Self.thumbnailCacheOptions.contains(value) ? value : Self.defaultThumbnailCacheMiB
    }

    var core: Process?
    // Detached from the window lifecycle: closing the last window must not
    // suspend NAS metrics, offline-volume alerts or persisted alert polling.
    var servicePollingTask: Task<Void, Never>?
    var startupDeadlineTask: Task<Void, Never>?
    var coreRestartTask: Task<Void, Never>?
    var coreSupervisor = CoreSupervisorPolicy()
    var coreHealthTask: Task<Void, Never>?
    var coreDesiredRunning = false
    var initialCoreLaunchAttempted = false
    @Published var coreLastIncident: String?
    @Published var corePortConflict: Int?
    @Published var corePortRecoveryBusy = false
    @Published var coreCommandWarning = false
    @Published var coreServiceWarnings: [String] = []
    static let coreStartupDeadlineSeconds: Double = 20

    var coreCommands: CoreCommandWriter?
    var coreGeneration: UUID?
    var outputPipe: Pipe?
    var coreOutputFramer = CoreLineFramer()
    var stopping = false
    var lastShareStatusPollAt = Date.distantPast

    var hasChildProcess: Bool { core != nil }
    var isRemoteEnabled: Bool { remoteAddress != nil }

    @Published var allowLANHTTP = LANAccessPolicy.prefersHTTP()
    @Published var prefersRemoteAccess = LANAccessPolicy.isPreferred()
    var lastAutomaticLANAttemptAt = Date.distantPast

    var canChangeSharedStorage: Bool {
        state == .online && !rootManagement.enabled && !storageSelectionPending &&
            !offlineCleanupPending && !exportRunning && !activatingMetadata && backupStatus?.running != true
    }

    var canAddOrSwitchStorageRoot: Bool {
        state == .online && rootManagement.connected && !rootManagement.busy &&
            !storageSelectionPending && !offlineCleanupPending && !exportRunning &&
            !activatingMetadata && backupStatus?.running != true
    }

    @Published var managedDisks: [ManagedDisk] = []
    @Published var diskManagementError: String?
    @Published var diskOperationPending = false
    var diskOperationDeadline: Task<Void, Never>?

    @Published var diskHealthReports: [String: DiskHealthReport] = [:]
    @Published var storageThreshold: StorageThreshold?
    @Published var elevatingDisks: Set<String> = []
    @Published var elevationMessage: String?

    @Published var tunnelState: TunnelState?
    @Published var frpState: FRPState?
    @Published var prefersFRPEnabled = FRPPersistencePolicy.isPreferred()
    @Published var prefersTunnelMode = TunnelPersistencePolicy.preferredMode()
    var frpAutoRestoreAttempted = false
    var tunnelAutoRestoreAttempted = false
    @Published var frpError: String?
    @Published var frpVersions: [FRPRelease] = []
    @Published var frpVersionsLoading = false
    @Published var selectedFRPVersion = ""
    @Published var tunnelAccounts: [TunnelAccount] = []
    @Published var tunnelZones: [TunnelZone] = []
    @Published var tunnelList: [TunnelEntry] = []
    @Published var tunnelIngress: [TunnelIngressRule] = []
    @Published var tunnelAPITokenConfigured = false
    @Published var tunnelAPIBusy = false
    @Published var tunnelAPIError: String?
    @Published var tunnelSelectedID: String? = TunnelPersistencePolicy.selectedTunnelID()
    let tunnelCredential = TunnelCredentialCoordinator(
        save: TunnelSecretVault.save,
        load: TunnelSecretVault.load,
        remove: TunnelSecretVault.remove
    )

    // Trash auto-cleanup (opt-in): configured here, enforced by Core's
    // sweeper, mirrored read-only to Web/Flutter over HTTP.
    @Published var trashRetention: TrashRetention = .disabled
    @Published var trashRetentionError: String?
    @Published var trashRetentionBusy = false
    var trashDeadline: Task<Void, Never>?
    // TMDB automatic scraping: the token lives in the local Keychain and is
    // mirrored to Core memory over the private pipe; Web and Flutter only
    // read the resulting configured flag.
    @Published var tmdbTokenConfigured = false
    @Published var tmdbTokenBusy = false
    @Published var tmdbTokenError: String?
    var tmdbCoreAcknowledged = false

    // Tianditu is configured solely by this Mac owner. Remote clients can
    // request proxied tiles, never the Keychain credential itself.
    @Published var mapKeyConfigured = false
    @Published var mapKeyBusy = false
    @Published var mapKeyError: String?
    var mapCoreAcknowledged = false

    // Outbound notifications (Bark / webhook): the channel config lives in the
    // local Keychain and is mirrored into Core memory the same way; the
    // secrets never reach UserDefaults, remote clients or the UI state.
    @Published var notifyConfigured = false
    @Published var notifyBusy = false
    @Published var notifyError: String?
    @Published var notifyTestResult: String?
    @Published var notifyStats: NotifyStats?
    var notifyCoreAcknowledged = false

    @Published var mcpDeveloperEnabled: Bool = false
    @Published var mcpStatusMessage: String?

    var canForgetOfflineShare: Bool {
        canChangeSharedStorage && sharedFolderPath == nil &&
            offlineSharedFolderPath != nil
    }

    private init() {
        refreshMCPDeveloperConfig()
    }
}
