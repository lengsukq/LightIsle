//go:build darwin && arm64

package main

import (
	"bufio"
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
	"sync/atomic"
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/aria2bin"
	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/automation"
	"github.com/lengsukq/lightisle/core/internal/backup"
	"github.com/lengsukq/lightisle/core/internal/diskmgmt"
	"github.com/lengsukq/lightisle/core/internal/downloads"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/maptiles"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
	"github.com/lengsukq/lightisle/core/internal/notify"
	"github.com/lengsukq/lightisle/core/internal/rootmigration"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
	"github.com/lengsukq/lightisle/core/internal/system"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

func main() {
	if runtime.GOOS != "darwin" || runtime.GOARCH != "arm64" {
		fmt.Fprintln(os.Stderr, "LightIsle only supports macOS arm64")
		os.Exit(1)
	}
	webRoot := flag.String("web-root", "", "directory containing built frontend assets")
	port := flag.Int("port", 16666, "local loopback port; 0 is reserved for tests")
	standalone := flag.Bool("standalone", false, "developer-only: run without a Mac App parent")
	dataDir := flag.String("data-dir", "", "private directory for SQLite account database")
	thumbnailCacheBytes := flag.Int64("thumbnail-cache-bytes", gallery.DefaultThumbnailCacheBytes, "bounded gallery thumbnail cache budget; set by the Mac App, never by HTTP")
	mediaWorkerPath := flag.String("media-worker", "", "trusted local media worker executable; defaults to the bundled sibling binary")
	flag.Parse()

	if *dataDir == "" {
		root, err := os.UserConfigDir()
		if err != nil {
			slog.Error("cannot locate application support", "error", err)
			os.Exit(1)
		}
		*dataDir = filepath.Join(root, "LightIsle")
	}
	if err := os.MkdirAll(*dataDir, 0700); err != nil {
		slog.Error("cannot create private data", "error", err)
		os.Exit(1)
	}
	canonicalDataDir, err := filepath.EvalSymlinks(*dataDir)
	if err != nil {
		slog.Error("cannot resolve private data directory", "error", err)
		os.Exit(1)
	}
	*dataDir, err = filepath.Abs(canonicalDataDir)
	if err != nil {
		slog.Error("cannot resolve absolute private data directory", "error", err)
		os.Exit(1)
	}
	processLock, err := backup.LockDataDir(*dataDir)
	if err != nil {
		slog.Error("data directory is already in use", "error", err)
		os.Exit(1)
	}
	defer processLock.Close()
	if backup.MetadataActivationPending(*dataDir) {
		slog.Error("offline metadata recovery was interrupted; refuse to start with partially migrated state")
		os.Exit(1)
	}
	if err := backup.FinalizeRecoverySessions(*dataDir); err != nil {
		slog.Error("cannot revoke restored browser sessions; refuse to expose recovered accounts", "error", err)
		os.Exit(1)
	}
	accountStore, err := auth.Open(filepath.Join(*dataDir, "accounts.sqlite"))
	if err != nil {
		slog.Error("cannot initialize accounts", "error", err)
		os.Exit(1)
	}
	defer accountStore.Close()
	// RootRegistry is the ONLY live source of NAS directory identity.
	// The retired single-share config is opened solely once on installations
	// with no registry state, then closed before any listeners or tasks start.
	rootRegistry, err := roots.Open(*dataDir)
	if err != nil {
		slog.Error("cannot initialize physical shared root registry", "error", err)
		os.Exit(1)
	}
	// Import the original physical directory into RootRegistry in place.
	// No media bytes or legacy grants are copied into the new identity.
	if !rootRegistry.HasConfiguration() {
		legacy, legacyErr := files.NewManager(*dataDir)
		if legacyErr != nil {
			slog.Warn("one-time shared-root migration needs manual recovery", "error", legacyErr)
		} else {
			if err := registerCurrentShareAsDefault(context.Background(), rootRegistry, legacy); err != nil {
				slog.Warn("existing shared directory requires explicit root registration", "error", err)
			}
			_ = legacy.Close()
		}
	}
	taskJournal, err := tasks.Open(*dataDir)
	if err != nil {
		slog.Error("cannot initialize durable task journal", "error", err)
		os.Exit(1)
	}
	defer taskJournal.Close()
	// Outbound notification channels stay inert until the Mac App sends the
	// owner-configured secrets over the private IPC pipe; the core never
	// persists them.
	notifyHub, notifyErr := notify.New(notify.Config{})
	if notifyErr != nil {
		slog.Error("cannot initialize notification hub", "error", notifyErr)
		os.Exit(1)
	}
	defer notifyHub.Close()
	automationManager, automationErr := automation.New(*dataDir, func(task automation.Task, state string, finished time.Time, exitCode int, html string) {
		if len(task.Notification.Channels) == 0 {
			return
		}
		emailMode := "builtin"
		emailSubject := ""
		if task.Notification.Email != nil {
			emailMode = task.Notification.Email.Mode
			if emailMode == "" {
				emailMode = "builtin"
			}
			emailSubject = task.Notification.Email.Subject
		}
		body := "脚本 " + task.ID + " 执行" + map[string]string{"success": "成功", "failure": "失败", "timeout": "超时"}[state] + "，请在自动化页面查看日志。"
		if task.LastError != "" {
			body += " " + task.LastError
		}
		notifyHub.NotifyTo(notify.Event{
			Code:         "automation_" + state,
			Title:        "自动化任务：" + task.Name,
			Body:         body,
			Severity:     map[string]string{"success": "info", "failure": "warning", "timeout": "warning"}[state],
			EmailMode:    emailMode,
			EmailHTML:    html,
			EmailSubject: emailSubject,
		}, task.Notification.Channels)
	})
	if automationErr != nil {
		slog.Error("cannot initialize automation tasks", "error", automationErr)
		os.Exit(1)
	}
	defer automationManager.Close()
	dispatchAlert := alertDispatcher(notifyHub)
	alertThresholds := tasks.OpenThresholdStore(filepath.Join(*dataDir, "storage-alerts.json"))
	trashRetention := tasks.OpenRetentionStore(filepath.Join(*dataDir, "trash-retention.json"))
	_ = maptiles.Default.ConfigureDiskCache(filepath.Join(*dataDir, "cache", "map-tiles"), maptiles.DefaultMapTileCacheBytes)
	mediaWorker := mediaworker.New(*mediaWorkerPath)
	backupService := backup.New(nil, *dataDir)
	backupService.ProtectDestinations(rootRegistry)
	defer backupService.Close()
	backupService.SetJournal(taskJournal)
	backupSchedule, err := backup.NewScheduler(backupService, *dataDir)
	if err != nil {
		slog.Error("cannot initialize backup schedule", "error", err)
		os.Exit(1)
	}
	defer backupSchedule.Close()
	// One shared drive backend serves the native parent IPC and authenticated
	// Web administrators. Guard even stale/offline root bindings and configured
	// backup destinations; never let a disk operation silently detach NAS data.
	var externalTransferRunning atomic.Bool
	configureSMBRootProvider(rootRegistry)
	diskmgmt.Shared().SetGuard(func(d diskmgmt.Disk, action string) error {
		if externalTransferRunning.Load() || backupService.Status().Running {
			return diskmgmt.ErrBusy
		}
		if action == "mount" {
			return nil
		}
		paths := []string{}
		for _, root := range rootRegistry.List() {
			paths = append(paths, root.Path)
			if diskmgmt.MatchesVolumeUUID(d, root.Binding.VolumeUUID) {
				return diskmgmt.ErrProtected
			}
		}
		schedule := backupSchedule.Status()
		paths = append(paths, schedule.Destination)
		if diskmgmt.MatchesVolumeUUID(d, schedule.DestinationVolumeUUID) {
			return diskmgmt.ErrProtected
		}
		for _, path := range paths {
			if path == "" {
				continue
			}
			mount := d.Mount
			if mount == "" {
				mount = "/Volumes/" + d.Name
			}
			if path == mount || strings.HasPrefix(path, mount+"/") {
				return diskmgmt.ErrProtected
			}
		}
		return nil
	})
	if *port < 0 || *port > 65535 {
		slog.Error("invalid port")
		os.Exit(2)
	}
	// No LAN listener without authentication and explicit user approval.
	listener, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", *port))
	if err != nil {
		slog.Error("cannot bind local API", "error", err)
		os.Exit(1)
	}
	defer listener.Close()
	// Download center: the aria2 binary comes from the same Homebrew
	// whitelist as ffmpeg/cloudflared; without it every endpoint reports the
	// honest download_unavailable reason. The journal stays usable so
	// historical tasks remain listed across upgrades.
	aria2Path, aria2Version, aria2Err := aria2bin.Locate()
	downloadPublisher := downloads.NewRegistryPublisher(rootRegistry)
	var downloadCenter *downloads.Manager
	if center, centerErr := downloads.New(downloads.Options{
		DataDir:      *dataDir,
		Binary:       aria2Path,
		LocateBinary: aria2bin.Locate,
		Publisher:    downloadPublisher,
		CanImport: func(owner int64, destination string) bool {
			selected, ok := rootRegistry.Default()
			return ok && accountStore.CanAccessRootForUser(owner, selected.ID, destination, true, false)
		},
		CanFetch: func(owner int64) bool {
			user, err := accountStore.GetUser(owner)
			return err == nil && user.Enabled && user.Role == auth.RoleAdmin
		},
		OnAlert: func(active bool) {
			if becameActive, err := taskJournal.SyncAlert("download_failed", active); err != nil {
				slog.Warn("download alert was not persisted", "active", active, "error", err)
			} else if becameActive {
				dispatchAlert("download_failed")
			}
		},
		OnTaskDone: func(filename string) {
			notifyHub.Notify(notify.Event{Code: "download_completed", Title: "下载完成", Body: "文件已发布：" + filename, Severity: "info"})
		},
	}); centerErr == nil {
		downloadCenter = center
		defer downloadCenter.Close()
		if aria2Err == nil {
			slog.Info("download center ready; aria2 starts on demand", "aria2", aria2Version)
		} else {
			slog.Info("download center unavailable", "reason", aria2Err.Error())
		}
	} else {
		slog.Warn("download center journal unavailable", "error", centerErr)
	}
	rootServer := server.NewWithRoots(*webRoot, accountStore, nil, nil, nil, taskJournal, rootRegistry,
		makeRootServices(*dataDir, mediaWorker, *thumbnailCacheBytes), server.RootServerOptions{
			EnableDiscovery: true, LegacyBackup: backupService, TrashRetention: trashRetention, DownloadCenter: downloadCenter,
		})
	downloadPublisher.SetOnPublished(rootServer.QueueMediaRefresh)
	defer rootServer.Close()
	var handler http.Handler = rootServer
	handler = server.WithAutomation(handler, accountStore, automationManager, notifyHub)
	httpServer := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// Optional in-app alert center: passive checks of disk and recorded task
	// status only. It does not mount drives, change system settings or trigger
	// user operations in the background.
	go monitorAlerts(ctx, rootRegistry, taskJournal, alertThresholds, accountStore, dispatchAlert)
	go monitorMetricHistory(ctx, taskJournal)
	// Preserve any legacy LightIsle trash during the transition to the macOS
	// Trash, including when an older installation enabled automatic purging.
	// The existing restore/inspection endpoints remain available.
	startUploadSweeper(ctx, rootRegistry, rootServer, accountStore)
	if rootServer != nil {
		// The original shared folder keeps its existing FSEvents watcher.
		// Additional roots only reconcile under the explicit developer preview.
		// No automatic backup is started without an owner-chosen destination.
		go newRootMediaMaintenance(rootRegistry, rootServer, taskJournal).Run(ctx)
	}
	// A burst of FSEvents must never trigger overlapping full scans or drop
	// a change because one of the media libraries is already scanning.
	// All native filesystem events target the registered default root. A full
	// reconcile is the safe fallback for FSEvents batches without a rootID.
	reconciler := newMediaReconciler(func() bool {
		selected, ok := rootRegistry.Default()
		if !ok {
			return false
		}
		return errors.Is(rootServer.ReconcileRootMedia(ctx, selected.ID), server.ErrRootMaintenanceBusy)
	}, func() bool { return false })
	go reconciler.Run(ctx)

	var remote *server.Remote
	// Only the trusted Mac App stdin pipe can request remote activation.
	// Remote access is never enabled by default or via a public HTTP endpoint.
	control := make(chan string, 8)
	rootCommands := &rootControl{output: os.Stdout}
	defer rootCommands.Close()
	tunnelCtl := newTunnelControl(ctx, *port, func(code string, active bool) {
		if becameActive, err := taskJournal.SyncAlert(code, active); err != nil {
			slog.Warn("tunnel status alert was not persisted", "code", code, "active", active, "error", err)
		} else if becameActive {
			dispatchAlert(code)
		}
	})
	frpCtl := newFRPControl(ctx)
	{
		rootCommands.registry = rootRegistry
		rootCommands.migration = rootmigration.NewWithStateDir(rootRegistry, *dataDir)
		rootCommands.migration.SetOnCompleted(func(targetRootID string) {
			rootServer.QueueMediaRefresh(targetRootID, "")
		})
		rootCommands.server = rootServer
		rootCommands.journal = taskJournal
		rootCommands.legacyBackupRunning = func() bool { return backupService.Status().Running }
		rootCommands.backupDestinations = func() []string {
			targets := []string{backupSchedule.Status().Destination}
			if latest := backupService.Status().LastSnapshot; latest != "" {
				targets = append(targets, filepath.Dir(latest))
			}
			return targets
		}
	}
	if !*standalone {
		// The Swift App owns the write end of stdin; EOF means App exited or crashed.
		go func() {
			s := bufio.NewScanner(os.Stdin)
			// A bounded batch of 32 changed directory paths may encode to
			// about 11 KiB of base64url JSON. The old 8 KiB scanner ceiling
			// terminated the parent-owned Core on a legitimate large event.
			s.Buffer(make([]byte, 4096), 16384)
			for s.Scan() {
				command := strings.TrimSpace(s.Text())
				if command == "shutdown" {
					break
				}
				if isAcceptedIPCCommand(command) {
					select {
					case control <- command:
					case <-ctx.Done():
						return
					}
				}
			}
			cancel()
		}()
	}
	monitor := &system.Collector{}
	exportDone := make(chan exportResult, 1)
	inventoryDone := make(chan inventoryResult, 1)
	var exportCancel context.CancelFunc
	inventoryActive := false
	notifyTestDone := make(chan error, 1)
	notifyTestActive := false
	go func() {
		for {
			select {
			case <-ctx.Done():
				if exportCancel != nil {
					exportCancel()
				}
				if remote != nil {
					remote.Stop()
				}
				return
			case err := <-notifyTestDone:
				notifyTestActive = false
				if err != nil {
					fmt.Fprintln(os.Stdout, "LIGHTISLE_NOTIFY_TEST_ERROR "+err.Error())
				} else {
					fmt.Fprintln(os.Stdout, "LIGHTISLE_NOTIFY_TESTED")
				}
			case result := <-exportDone:
				exportCancel = nil
				emitExportOutcome(result, &externalTransferRunning)
			case result := <-inventoryDone:
				inventoryActive = false
				emitBackupInventoryOutcome(result)
			case command := <-control:
				if handleMapSettings(command) {
					continue
				}
				if rootCommands.handle(ctx, command) {
					continue
				}
				if tunnelCtl.handle(ctx, command) {
					continue
				}
				if frpCtl.handle(command) {
					continue
				}
				if handleDiskIPC(ctx, command) {
					continue
				}
				if strings.HasPrefix(command, "index root ") {
					if event, ok := parseNativeRootMediaEvent(strings.TrimPrefix(command, "index root ")); ok {
						rootServer.QueueNativeRootRefreshDirs(event.RootID, event.Generation, event.Dirs)
					}
					continue
				}
				if strings.HasPrefix(command, "index dirs ") {
					encoded := strings.TrimPrefix(command, "index dirs ")
					if len(encoded) > 12000 {
						continue
					}
					payload, err := base64.RawURLEncoding.DecodeString(encoded)
					if err != nil || len(payload) > 8192 {
						continue
					}
					var dirs []string
					if err := json.Unmarshal(payload, &dirs); err != nil {
						continue
					}
					// Old native FSEvents events have no rootID. Treat them only as
					// a request to scan the registered default root; never reuse
					// their directory names against an unrelated volume.
					if len(dirs) != 0 {
						reconciler.Request()
					}
					continue
				}
				if handleAlertSettings(command, taskJournal, alertThresholds) {
					continue
				}
				// The TMDB Read Access Token arrives only from the trusted Mac
				// App (Keychain storage) and stays in Core memory; it is never
				// persisted, logged or echoed back.
				// Trash auto-cleanup is opt-in and only settable by the Mac
				// App; Web/Flutter get a read-only HTTP view.
				if handleTrashRetentionSettings(command, trashRetention) {
					continue
				}
				if handleRootCinemaTokenSettings(command, rootServer) {
					continue
				}
				if handleNotificationIPC(command, notifyHub, &notifyTestActive, notifyTestDone) {
					continue
				}
				if handleExportIPC(ctx, command, rootRegistry, rootServer, &exportCancel, &externalTransferRunning, exportDone) {
					continue
				}
				if command == "index scan" {
					reconciler.Request()
					continue
				}
				if handleBackupIPC(ctx, command, backupService, backupSchedule, &inventoryActive, inventoryDone) {
					continue
				}
				if handleSMBCommand(ctx, command) {
					continue
				}
				if handleAdminShareRemoteIPC(ctx, command, accountStore, rootRegistry, reconciler, monitor, &remote, handler, *dataDir, *port) {
					continue
				}
			}
		}
	}()
	go func() {
		<-ctx.Done()
		shutdownCtx, release := context.WithTimeout(context.Background(), 4*time.Second)
		defer release()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			slog.Warn("HTTP shutdown failed", "error", err)
		}
	}()

	emitInitialReadyState(listener.Addr().String(), accountStore, rootRegistry)
	if err := httpServer.Serve(listener); err != nil && err != http.ErrServerClosed {
		slog.Error("HTTP server failure", "error", err)
		os.Exit(1)
	}
}
