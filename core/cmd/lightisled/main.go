//go:build darwin && arm64

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/apps"
	"github.com/lengsukq/lightisle/core/internal/aria2bin"
	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/automation"
	"github.com/lengsukq/lightisle/core/internal/backup"
	"github.com/lengsukq/lightisle/core/internal/diagnostics"
	"github.com/lengsukq/lightisle/core/internal/diskmgmt"
	"github.com/lengsukq/lightisle/core/internal/downloads"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/maptiles"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
	"github.com/lengsukq/lightisle/core/internal/notify"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
	"github.com/lengsukq/lightisle/core/internal/system"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

// Exit codes consumed by the native supervisor. These failures require a
// local owner action, so restarting automatically would repeat the failure.
const (
	exitCriticalData           = 70
	exitDataDirectoryInUse     = 71
	exitRecoveryPending        = 72
	exitPortInUse              = 73
	exitRecoverySessionsFailed = 74
	exitListenFailed           = 76
)

const (
	ipcControlBufferSize     = 8
	maxIndexDirsEncodedBytes = 12000
	maxIndexDirsPayloadBytes = 8192
)

func main() {
	if runtime.GOOS != "darwin" || runtime.GOARCH != "arm64" {
		fmt.Fprintln(os.Stderr, "LightIsle only supports macOS arm64")
		os.Exit(1)
	}
	if len(os.Args) > 1 && os.Args[1] == "mcp" {
		runMCPSubcommand(os.Args[2:])
		return
	}

	webRoot := flag.String("web-root", "", "directory containing built frontend assets")
	port := flag.Int("port", 16666, "local loopback port; 0 is reserved for tests")
	standalone := flag.Bool("standalone", false, "developer-only: run without a Mac App parent")
	dataDirFlag := flag.String("data-dir", "", "private directory for SQLite account database")
	thumbnailCacheBytes := flag.Int64("thumbnail-cache-bytes", gallery.DefaultThumbnailCacheBytes, "bounded gallery thumbnail cache budget; set by the Mac App, never by HTTP")
	mediaWorkerPath := flag.String("media-worker", "", "trusted local media worker executable; defaults to the bundled sibling binary")
	flag.Parse()

	dataDir, err := resolvePrivateDataDir(*dataDirFlag)
	if err != nil {
		slog.Error("invalid private data directory", "error", err)
		os.Exit(exitCriticalData)
	}
	processLock, err := backup.LockDataDir(dataDir)
	if err != nil {
		slog.Error("data directory is already in use", "error", err)
		os.Exit(exitDataDirectoryInUse)
	}
	defer processLock.Close()

	localDiagnostics := diagnostics.Start(dataDir)
	defer localDiagnostics.Close()
	slog.SetDefault(slog.New(localDiagnostics.Handler()))
	diagnostics.Emit(context.Background(), slog.LevelInfo, diagnostics.Event{
		Component: "core", Operation: "startup", Code: "core_starting",
	})
	exitWithDiagnostics := func(code int) {
		localDiagnostics.Close()
		os.Exit(code)
	}

	if backup.MetadataActivationPending(dataDir) {
		slog.Error("offline metadata recovery was interrupted; refuse to start with partially migrated state")
		exitWithDiagnostics(exitRecoveryPending)
	}
	if err := backup.FinalizeRecoverySessions(dataDir); err != nil {
		slog.Error("cannot revoke restored browser sessions; refuse to expose recovered accounts", "error", err)
		exitWithDiagnostics(exitRecoverySessionsFailed)
	}
	accountStore, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		slog.Error("cannot initialize accounts", "error", err)
		exitWithDiagnostics(exitCriticalData)
	}
	defer accountStore.Close()

	rootRegistry, err := roots.Open(dataDir)
	if err != nil {
		slog.Error("cannot initialize physical shared root registry", "error", err)
		exitWithDiagnostics(exitCriticalData)
	}
	importInitialLegacyRootIfNeeded(rootRegistry, dataDir)
	retireUnreferencedRootSQLiteOnStartup(dataDir, rootRegistry.List())

	if *port < 0 || *port > 65535 {
		slog.Error("invalid port")
		exitWithDiagnostics(2)
	}
	listener, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", *port))
	if err != nil {
		slog.Error("cannot bind local API", "error", err)
		if errors.Is(err, syscall.EADDRINUSE) {
			exitWithDiagnostics(exitPortInUse)
		}
		exitWithDiagnostics(exitListenFailed)
	}
	defer listener.Close()

	taskJournal, err := tasks.Open(dataDir)
	if err != nil {
		slog.Warn("task history unavailable; continuing with NAS services", "error", err)
	} else {
		defer taskJournal.Close()
	}

	notifyHub, notifyErr := notify.New(notify.Config{})
	if notifyErr != nil {
		slog.Error("cannot initialize notification hub", "error", notifyErr)
		exitWithDiagnostics(1)
	}
	defer notifyHub.Close()

	automationManager := openAutomationWithNotifications(dataDir, notifyHub)
	if err := automationManager.Reload(); err != nil {
		slog.Warn("automation unavailable; continuing with NAS services", "error", err)
	}
	defer automationManager.Close()

	execPath, _ := os.Executable()
	appsManager := apps.NewManager(dataDir, execPath, automationManager)
	appsManager.SetConfiguredChannels(notifyHub.ConfiguredChannels)
	appsManager.SetExternalVolumesProvider(func() []apps.ExternalVolumeInfo {
		vols := system.Volumes()
		out := make([]apps.ExternalVolumeInfo, 0, len(vols))
		for _, v := range vols {
			out = append(out, apps.ExternalVolumeInfo{
				Name:       v.Name,
				Mount:      v.Mount,
				Filesystem: v.Filesystem,
				TotalBytes: v.Total,
				FreeBytes:  v.Free,
				ReadOnly:   v.ReadOnly,
			})
		}
		return out
	})
	if err := appsManager.Reload(); err != nil {
		slog.Warn("apps manager unavailable; continuing with NAS services", "error", err)
	}
	defer appsManager.Close()

	dispatchAlert := alertDispatcher(notifyHub)
	alertThresholds := tasks.OpenThresholdStore(filepath.Join(dataDir, "storage-alerts.json"))
	trashRetention := tasks.OpenRetentionStore(filepath.Join(dataDir, "trash-retention.json"))
	if cacheErr := maptiles.Default.ConfigureDiskCache(filepath.Join(dataDir, "cache", "map-tiles"), maptiles.DefaultMapTileCacheBytes); cacheErr != nil {
		slog.Warn("map tile disk cache unavailable", "error", cacheErr)
	}

	mediaWorker := mediaworker.New(*mediaWorkerPath)
	backupService := backup.New(nil, dataDir)
	backupService.ProtectDestinations(rootRegistry)
	defer backupService.Close()
	backupService.SetJournal(taskJournal)
	backupSchedule, err := backup.NewScheduler(backupService, dataDir)
	if err != nil {
		slog.Warn("backup schedule unavailable; manual backup remains available", "error", err)
	} else {
		defer backupSchedule.Close()
	}

	var externalTransferRunning atomic.Bool
	configureSMBRootProvider(rootRegistry)
	installDiskProtectionGuard(rootRegistry, backupService, backupSchedule, appsManager, &externalTransferRunning)

	downloadPublisher := downloads.NewRegistryPublisher(rootRegistry, accountStore)
	downloadCenter := openOptionalDownloadCenter(
		dataDir, rootRegistry, accountStore, taskJournal, notifyHub, dispatchAlert, downloadPublisher,
	)
	if downloadCenter != nil {
		defer downloadCenter.Close()
	}

	rootServer := server.NewWithRoots(*webRoot, accountStore, nil, nil, nil, taskJournal, rootRegistry,
		makeRootServices(dataDir, mediaWorker, *thumbnailCacheBytes), server.RootServerOptions{
			EnableDiscovery: true, LegacyBackup: backupService, TrashRetention: trashRetention, DownloadCenter: downloadCenter,
		})
	downloadPublisher.SetOnPublished(rootServer.QueueMediaRefresh)
	defer rootServer.Close()

	var handler http.Handler = rootServer
	handler = server.WithAutomation(handler, accountStore, automationManager, notifyHub)
	handler = server.WithApps(handler, dataDir, accountStore, appsManager)
	handler = diagnostics.HTTP(handler)
	httpServer := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	var monitors sync.WaitGroup
	defer func() {
		cancel()
		monitors.Wait()
	}()
	monitors.Go(func() {
		monitorAlerts(ctx, rootRegistry, rootServer, taskJournal, alertThresholds, accountStore, dispatchAlert)
	})
	if taskJournal != nil {
		monitors.Go(func() { monitorMetricHistory(ctx, taskJournal) })
	}
	monitors.Go(func() { newRootMediaMaintenance(rootRegistry, rootServer, taskJournal).Run(ctx) })
	// Preserve any legacy LightIsle trash during the transition to the macOS
	// Trash, including when an older installation enabled automatic purging.
	// The existing restore/inspection endpoints remain available.
	startUploadSweeper(ctx, rootRegistry, rootServer, accountStore)

	var remote atomic.Pointer[server.Remote]
	rootServer.SetTailscaleURLProvider(func() (string, bool) {
		if r := remote.Load(); r != nil {
			return r.TailscaleURL, strings.HasPrefix(r.URL, "https://")
		}
		return "", false
	})
	appsManager.SetEndpointProvider(func() (string, string) {
		localBase := "http://" + listener.Addr().String()
		if r := remote.Load(); r != nil {
			return localBase, r.URL
		}
		return localBase, ""
	})
	appsManager.EnableSandboxBridge()

	rootCommands := newDaemonRootControl(dataDir, rootRegistry, accountStore, rootServer, taskJournal, backupService, backupSchedule)
	defer rootCommands.Close()

	control := make(chan string, ipcControlBufferSize)
	if !*standalone {
		startParentStdinMonitor(ctx, cancel, control)
	}
	dispatcher := &ipcCommandDispatcher{
		dataDir:                 dataDir,
		port:                    *port,
		localDiagnostics:        localDiagnostics,
		accountStore:            accountStore,
		rootRegistry:            rootRegistry,
		rootServer:              rootServer,
		appsManager:             appsManager,
		automationManager:       automationManager,
		taskJournal:             taskJournal,
		alertThresholds:         alertThresholds,
		notifyHub:               notifyHub,
		backupService:           backupService,
		backupSchedule:          backupSchedule,
		rootCommands:            rootCommands,
		tunnelCtl:               newDaemonTunnelControl(ctx, *port, taskJournal, dispatchAlert),
		frpCtl:                  newFRPControl(ctx),
		httpHandler:             handler,
		remote:                  &remote,
		externalTransferRunning: &externalTransferRunning,
		control:                 control,
		monitor:                 &system.Collector{},
		exportDone:              make(chan exportResult, 1),
		inventoryDone:           make(chan inventoryResult, 1),
		notifyTestDone:          make(chan error, 1),
	}
	go dispatcher.runLoop(ctx)
	go shutdownHTTPOnCancel(ctx, httpServer)

	syncInitialRootGenerations(ctx, rootRegistry, accountStore)
	emitInitialReadyState(listener.Addr().String(), accountStore, rootRegistry)
	diagnostics.Emit(ctx, slog.LevelInfo, diagnostics.Event{
		Component: "core", Operation: "startup", Code: "core_ready",
	})
	if taskJournal == nil {
		writeStdoutLine("LIGHTISLE_SERVICE_WARNING task_history")
	}
	if backupSchedule == nil {
		writeStdoutLine("LIGHTISLE_SERVICE_WARNING backup_schedule")
	}
	if err := httpServer.Serve(listener); err != nil && err != http.ErrServerClosed {
		slog.Error("HTTP server failure", "error", err)
		exitWithDiagnostics(1)
	}
}

func runMCPSubcommand(args []string) {
	mcpFlags := flag.NewFlagSet("mcp", flag.ContinueOnError)
	mcpDataDir := mcpFlags.String("data-dir", "", "private directory for LightIsle data")
	_ = mcpFlags.Parse(args)
	dir := *mcpDataDir
	if dir == "" {
		dir = os.Getenv("LIGHTISLE_DATA_DIR")
	}
	if dir == "" {
		if root, err := os.UserConfigDir(); err == nil && root != "" {
			dir = filepath.Join(root, "LightIsle")
		} else if home, herr := os.UserHomeDir(); herr == nil && home != "" {
			dir = filepath.Join(home, "Library", "Application Support", "LightIsle")
		}
	}
	execPath, _ := os.Executable()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := apps.RunMCP(ctx, dir, execPath, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func resolvePrivateDataDir(configured string) (string, error) {
	dir := configured
	if dir == "" {
		root, err := os.UserConfigDir()
		if err != nil {
			return "", fmt.Errorf("cannot locate application support: %w", err)
		}
		dir = filepath.Join(root, "LightIsle")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", fmt.Errorf("cannot create private data: %w", err)
	}
	canonicalDataDir, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return "", fmt.Errorf("cannot resolve private data directory: %w", err)
	}
	return filepath.Abs(canonicalDataDir)
}

func importInitialLegacyRootIfNeeded(rootRegistry *roots.Registry, dataDir string) {
	if rootRegistry.HasConfiguration() {
		return
	}
	legacy, legacyErr := files.NewManager(dataDir)
	if legacyErr != nil {
		slog.Warn("one-time shared-root migration needs manual recovery", "error", legacyErr)
		return
	}
	defer func() { _ = legacy.Close() }()
	if err := registerCurrentShareAsDefault(context.Background(), rootRegistry, legacy); err != nil {
		slog.Warn("existing shared directory requires explicit root registration", "error", err)
	}
}

func openAutomationWithNotifications(dataDir string, notifyHub *notify.Hub) *automation.Manager {
	stateLabels := map[string]string{"success": "成功", "failure": "失败", "timeout": "超时"}
	stateSeverities := map[string]string{"success": "info", "failure": "warning", "timeout": "warning"}

	return automation.Open(dataDir, func(task automation.Task, state string, _ time.Time, _ int, html string, report func(string, string)) {
		if len(task.Notification.Channels) == 0 {
			return
		}
		emailMode := "builtin"
		emailSubject := ""
		if task.Notification.Email != nil {
			if task.Notification.Email.Mode != "" {
				emailMode = task.Notification.Email.Mode
			}
			emailSubject = task.Notification.Email.Subject
		}
		body := "脚本 " + task.ID + " 执行" + stateLabels[state] + "，请在自动化页面查看日志。"
		if task.LastError != "" {
			body += " " + task.LastError
		}
		notifyHub.NotifyTracked(notify.Event{
			Code:         "automation_" + state,
			Title:        "自动化任务：" + task.Name,
			Body:         body,
			Severity:     stateSeverities[state],
			EmailMode:    emailMode,
			EmailHTML:    html,
			EmailSubject: emailSubject,
		}, task.Notification.Channels, report)
	})
}

func installDiskProtectionGuard(
	rootRegistry *roots.Registry,
	backupService *backup.Service,
	backupSchedule *backup.Scheduler,
	appsManager *apps.Manager,
	externalTransferRunning *atomic.Bool,
) {
	diskmgmt.Shared().SetGuard(func(d diskmgmt.Disk, action string) error {
		if externalTransferRunning.Load() || backupService.Status().Running {
			return diskmgmt.ErrBusy
		}
		if action == "mount" {
			return nil
		}
		paths := make([]string, 0, len(rootRegistry.List())+4)
		for _, root := range rootRegistry.List() {
			paths = append(paths, root.Path)
			if diskmgmt.MatchesVolumeUUID(d, root.Binding.VolumeUUID) {
				return diskmgmt.ErrProtected
			}
		}
		if appsManager != nil {
			paths = append(paths, appsManager.ProtectedHostDirs()...)
			for _, volUUID := range appsManager.ProtectedVolumeUUIDs() {
				if diskmgmt.MatchesVolumeUUID(d, volUUID) {
					return diskmgmt.ErrProtected
				}
			}
		}
		if backupSchedule == nil {
			return diskmgmt.ErrProtected
		}
		schedule := backupSchedule.Status()
		paths = append(paths, schedule.Destination)
		if diskmgmt.MatchesVolumeUUID(d, schedule.DestinationVolumeUUID) {
			return diskmgmt.ErrProtected
		}
		mount := d.Mount
		if mount == "" {
			mount = "/Volumes/" + d.Name
		}
		for _, path := range paths {
			if path != "" && (path == mount || strings.HasPrefix(path, mount+"/")) {
				return diskmgmt.ErrProtected
			}
		}
		return nil
	})
}

func openOptionalDownloadCenter(
	dataDir string,
	rootRegistry *roots.Registry,
	accountStore *auth.Store,
	taskJournal *tasks.Journal,
	notifyHub *notify.Hub,
	dispatchAlert func(string),
	publisher *downloads.RegistryPublisher,
) *downloads.Manager {
	aria2Path, aria2Version, aria2Err := aria2bin.Locate()
	center, centerErr := downloads.New(downloads.Options{
		DataDir:      dataDir,
		Binary:       aria2Path,
		LocateBinary: aria2bin.Locate,
		Publisher:    publisher,
		CanImport: func(owner int64, destination string) bool {
			selected, ok := rootRegistry.Default()
			return ok && accountStore.CanAccessRootForUser(owner, selected.ID, destination, true, false)
		},
		CanFetch: func(owner int64) bool {
			user, err := accountStore.GetUser(owner)
			return err == nil && user.Enabled && user.Role == auth.RoleAdmin
		},
		OnAlert: func(active bool) {
			if taskJournal == nil {
				return
			}
			if becameActive, err := taskJournal.SyncAlert("download_failed", active); err != nil {
				slog.Warn("download alert was not persisted", "active", active, "error", err)
			} else if becameActive {
				dispatchAlert("download_failed")
			}
		},
		OnTaskDone: func(filename string) {
			notifyHub.Notify(notify.Event{
				Code: "download_completed", Title: "下载完成", Body: "文件已发布：" + filename, Severity: "info",
			})
		},
	})
	if centerErr != nil {
		slog.Warn("download center journal unavailable", "error", centerErr)
		return nil
	}
	if aria2Err == nil {
		slog.Info("download center ready; aria2 starts on demand", "aria2", aria2Version)
	} else {
		slog.Info("download center unavailable", "reason", aria2Err.Error())
	}
	return center
}

func newDaemonRootControl(
	dataDir string,
	rootRegistry *roots.Registry,
	accountStore *auth.Store,
	rootServer *server.RootServer,
	taskJournal *tasks.Journal,
	backupService *backup.Service,
	backupSchedule *backup.Scheduler,
) *rootControl {
	return &rootControl{
		dataDir:             dataDir,
		output:              ipcStdout,
		registry:            rootRegistry,
		accounts:            accountStore,
		server:              rootServer,
		journal:             taskJournal,
		legacyBackupRunning: func() bool { return backupService.Status().Running },
		backupDestinations: func() []string {
			var targets []string
			if backupSchedule != nil {
				targets = append(targets, backupSchedule.Status().Destination)
			}
			if latest := backupService.Status().LastSnapshot; latest != "" {
				targets = append(targets, filepath.Dir(latest))
			}
			return targets
		},
	}
}

func newDaemonTunnelControl(ctx context.Context, port int, taskJournal *tasks.Journal, dispatchAlert func(string)) *tunnelControl {
	return newTunnelControl(ctx, port, func(code string, active bool) {
		if taskJournal == nil {
			return
		}
		if becameActive, err := taskJournal.SyncAlert(code, active); err != nil {
			slog.Warn("tunnel status alert was not persisted", "code", code, "active", active, "error", err)
		} else if becameActive {
			dispatchAlert(code)
		}
	})
}

func startParentStdinMonitor(ctx context.Context, cancel context.CancelFunc, control chan<- string) {
	go watchCoreParent(ctx, os.Getppid(), cancel)
	go func() {
		readIPCCommandLines(os.Stdin, os.Stderr, func(command string) bool {
			if !isAcceptedIPCCommand(command) {
				return true
			}
			select {
			case control <- command:
				return true
			case <-ctx.Done():
				return false
			}
		})
		cancel()
	}()
}

func shutdownHTTPOnCancel(ctx context.Context, httpServer *http.Server) {
	<-ctx.Done()
	shutdownCtx, release := context.WithTimeout(context.Background(), 4*time.Second)
	defer release()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		slog.Warn("HTTP shutdown failed", "error", err)
	}
}

func syncInitialRootGenerations(ctx context.Context, rootRegistry *roots.Registry, accountStore *auth.Store) {
	for _, r := range rootRegistry.List() {
		if lease, err := rootRegistry.Acquire(ctx, r.ID); err == nil {
			_ = accountStore.SyncVerifiedRootGeneration(r.ID, r.Generation)
			_ = lease.Close()
		}
	}
}

type ipcCommandDispatcher struct {
	dataDir                 string
	port                    int
	localDiagnostics        *diagnostics.Logger
	accountStore            *auth.Store
	rootRegistry            *roots.Registry
	rootServer              *server.RootServer
	appsManager             *apps.Manager
	automationManager       *automation.Manager
	taskJournal             *tasks.Journal
	alertThresholds         *tasks.ThresholdStore
	notifyHub               *notify.Hub
	backupService           *backup.Service
	backupSchedule          *backup.Scheduler
	rootCommands            *rootControl
	tunnelCtl               *tunnelControl
	frpCtl                  *frpControl
	httpHandler             http.Handler
	remote                  *atomic.Pointer[server.Remote]
	externalTransferRunning *atomic.Bool

	control          <-chan string
	monitor          *system.Collector
	exportDone       chan exportResult
	inventoryDone    chan inventoryResult
	exportCancel     context.CancelFunc
	inventoryActive  bool
	notifyTestDone   chan error
	notifyTestActive bool
}

func (d *ipcCommandDispatcher) runLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			if d.exportCancel != nil {
				d.exportCancel()
			}
			if r := d.remote.Swap(nil); r != nil {
				r.Stop()
			}
			return
		case err := <-d.notifyTestDone:
			d.notifyTestActive = false
			if err != nil {
				writeStdoutLine("LIGHTISLE_NOTIFY_TEST_ERROR " + sanitizeIPCText(err.Error()))
			} else {
				writeStdoutLine("LIGHTISLE_NOTIFY_TESTED")
			}
		case result := <-d.exportDone:
			d.exportCancel = nil
			emitExportOutcome(result, d.externalTransferRunning)
		case result := <-d.inventoryDone:
			d.inventoryActive = false
			emitBackupInventoryOutcome(result)
		case command := <-d.control:
			d.dispatch(ctx, command)
		}
	}
}

func (d *ipcCommandDispatcher) dispatch(ctx context.Context, command string) {
	switch {
	case d.handleComputerFiles(command):
	case d.handleDiagnosticsDebug(ctx, command):
	case handleMapSettings(command):
	case d.rootCommands.handle(ctx, command):
	case handleSpacesIPC(ctx, command, d.accountStore, d.rootRegistry, d.rootServer):
	case handleAppsIPC(ctx, command, d.appsManager, d.automationManager, d.accountStore):
	case d.tunnelCtl.handle(ctx, command):
	case d.frpCtl.handle(command):
	case handleDiskIPC(ctx, command):
	case d.handleMediaRefresh(command):
	case handleAlertSettings(command, d.taskJournal, d.alertThresholds):
	case handleRootCinemaTokenSettings(command, d.rootServer):
	case handleNotificationIPC(command, d.notifyHub, &d.notifyTestActive, d.notifyTestDone):
	case handleExportIPC(ctx, command, d.rootRegistry, d.rootServer, &d.exportCancel, d.externalTransferRunning, d.exportDone):
	case handleBackupIPC(ctx, command, d.backupService, d.backupSchedule, &d.inventoryActive, d.inventoryDone):
	case handleSMBCommand(ctx, command):
	default:
		_ = handleAdminShareRemoteIPC(
			ctx, command, d.accountStore, d.rootRegistry, d.rootServer,
			d.monitor, d.remote, d.httpHandler, d.dataDir, d.port,
		)
	}
}

func (d *ipcCommandDispatcher) handleComputerFiles(command string) bool {
	if command != "computer-files status" && command != "computer-files on" && command != "computer-files off" {
		return false
	}
	if command != "computer-files status" {
		if err := d.accountStore.SetComputerFilesEnabled(command == "computer-files on"); err != nil {
			writeStdoutLine("LIGHTISLE_COMPUTER_FILES_ERROR")
			return true
		}
	}
	if d.accountStore.ComputerFilesEnabled() {
		writeStdoutLine("LIGHTISLE_COMPUTER_FILES 1")
	} else {
		writeStdoutLine("LIGHTISLE_COMPUTER_FILES 0")
	}
	return true
}

func (d *ipcCommandDispatcher) handleDiagnosticsDebug(ctx context.Context, command string) bool {
	if command != "diagnostics debug" {
		return false
	}
	d.localDiagnostics.DebugForHalfHour()
	diagnostics.Emit(ctx, slog.LevelInfo, diagnostics.Event{
		Component: "core", Operation: "diagnostics", Code: "debug_enabled",
	})
	return true
}

func (d *ipcCommandDispatcher) handleMediaRefresh(command string) bool {
	if command == "index scan" {
		queueDefaultMediaRefresh(d.rootRegistry, d.rootServer, []string{"."})
		return true
	}
	if strings.HasPrefix(command, "index root ") {
		if event, ok := parseNativeRootMediaEvent(strings.TrimPrefix(command, "index root ")); ok {
			d.rootServer.QueueNativeRootRefreshDirs(event.RootID, event.Generation, event.Dirs)
		}
		return true
	}
	if !strings.HasPrefix(command, "index dirs ") {
		return false
	}
	encoded := strings.TrimPrefix(command, "index dirs ")
	if len(encoded) > maxIndexDirsEncodedBytes {
		return true
	}
	payload, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(payload) > maxIndexDirsPayloadBytes {
		return true
	}
	var dirs []string
	if err := json.Unmarshal(payload, &dirs); err == nil && len(dirs) != 0 {
		queueDefaultMediaRefresh(d.rootRegistry, d.rootServer, dirs)
	}
	return true
}
