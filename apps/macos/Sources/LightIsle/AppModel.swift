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
struct ManagedDisk: Decodable, Identifiable, Equatable {
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
    let appsCenter = NativeAppsModel()
    let externalVolumeCoordinator = ExternalVolumePermissionCoordinator()

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
    var connectionDetailNavigationRequest: ((ConnectionDetail) -> Void)?
    var appsSectionNavigationRequest: ((AppsAndContainersSection) -> Void)?
    var settingsDetailNavigationRequest: ((PreferencesSection) -> Void)?
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
    func navigateToConnectionDetail(_ detail: ConnectionDetail) {
        if let connectionDetailNavigationRequest {
            connectionDetailNavigationRequest(detail)
        } else {
            selectedSidebarPage = .services
        }
    }
    func navigateToAppsSection(_ section: AppsAndContainersSection) {
        appsCenter.workspaceSection = section
        if let appsSectionNavigationRequest {
            appsSectionNavigationRequest(section)
        } else {
            selectedSidebarPage = .containers
        }
    }
    func navigateToSettingsDetail(_ detail: PreferencesSection) {
        if let settingsDetailNavigationRequest {
            settingsDetailNavigationRequest(detail)
        } else {
            selectedSidebarPage = .settings
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
    let servicePresence = NativeServicePresenceCoordinator()
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
    @Published var storageSelectionMessage: String?

    @Published var isConfigured: Bool?
    @Published var initializationError: String?
    @Published var initializing = false
    @Published var metrics: HostMetrics?
    @Published var metricHistory: [MetricHistoryPoint] = []
    @Published var powerSnapshot: NativePowerSnapshot?
    var lastPowerPollAt = Date.distantPast
    var powerPollTask: Task<Void, Never>?
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
    @Published var computerFilesEnabled: Bool?
    @Published var computerFilesError: String?
    @Published var smbState: NativeSMBStatus?
    @Published var smbBusy = false
    @Published var smbError: String?
    @Published var smbNotice: String?
    @Published var timeMachineDiagnostics: TimeMachineDiagnostics?
    @Published var timeMachineChecking = false
    var timeMachineDiagnosticsGeneration: UInt64 = 0

    @Published var backupSchedule: NASBackupSchedule?
    @Published var portError: String?
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

    var canAddOrSwitchStorageRoot: Bool {
        state == .online && rootManagement.connected && !rootManagement.busy &&
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

    @Published var hasSavedTmdbToken = false
    @Published var hasSavedMapKey = false
    @Published var hasSavedNotifySecret = false

    private init() {
        if !isPresentationPreview {
            refreshCachedSecretPresence()
            externalVolumeCoordinator.start(appModel: self)
        }
    }
}
