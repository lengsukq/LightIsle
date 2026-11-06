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
	"strconv"
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
		DataDir:   *dataDir,
		Binary:    aria2Path,
		Publisher: downloadPublisher,
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
				if strings.HasPrefix(command, "roots ") || command == "remote on" || command == "remote http on" || command == "remote off" || strings.HasPrefix(command, "share set ") || strings.HasPrefix(command, "share forget ") || command == "share retry" || command == "share status" || command == "disk list" || strings.HasPrefix(command, "disk action ") || strings.HasPrefix(command, "disk smart ") || command == "index scan" || strings.HasPrefix(command, "index dirs ") || strings.HasPrefix(command, "index root ") || strings.HasPrefix(command, "admin init ") || strings.HasPrefix(command, "admin verify ") || strings.HasPrefix(command, "admin reset ") || command == "stats" || command == "stats summary" || command == "alerts status" || command == "alerts threshold" || strings.HasPrefix(command, "alerts threshold ") || command == "backup status" || command == "backup cancel" || strings.HasPrefix(command, "backup start ") || strings.HasPrefix(command, "backup metadata start ") || strings.HasPrefix(command, "backup restore ") || strings.HasPrefix(command, "backup inventory ") || command == "smb status" || command == "backup schedule status" || command == "backup schedule off" || strings.HasPrefix(command, "backup schedule set ") || strings.HasPrefix(command, "export start ") || command == "export cancel" || command == "export history" || strings.HasPrefix(command, "tunnel ") || strings.HasPrefix(command, "frp ") || strings.HasPrefix(command, "cinema tmdb ") || strings.HasPrefix(command, "map tianditu ") || strings.HasPrefix(command, "trash ") || strings.HasPrefix(command, "notify ") {
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
	type exportResult struct {
		path string
		err  error
	}
	exportDone := make(chan exportResult, 1)
	type inventoryResult struct {
		inventory backup.SnapshotInventory
		err       error
	}
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
				externalTransferRunning.Store(false)
				if result.err != nil {
					fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_ERROR "+base64.RawURLEncoding.EncodeToString([]byte(result.err.Error())))
				} else {
					fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_OK "+base64.RawURLEncoding.EncodeToString([]byte(result.path)))
				}
			case result := <-inventoryDone:
				inventoryActive = false
				if result.err != nil {
					fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR "+result.err.Error())
					continue
				}
				payload, err := json.Marshal(result.inventory)
				if err != nil {
					fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR backup_inventory_encode_failed")
				} else {
					fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_INVENTORY "+base64.RawURLEncoding.EncodeToString(payload))
				}
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
				if command == "share status" {
					// A read-only physical identity check, not a reconnect. The
					// native menu-bar app uses it to detect a disk unplugged while
					// nobody has an HTTP file-management page open.
					path, online := registeredDefaultState(rootRegistry)
					if online {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_STATUS 1")
					} else {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_STATUS 0")
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_OFFLINE_PATH "+base64.RawURLEncoding.EncodeToString([]byte(path)))
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
				if command == "export history" {
					var data []byte
					err := withDefaultManager(ctx, rootRegistry, rootServer, func(manager *files.Manager) error {
						items, err := manager.ListTransfers()
						if err != nil {
							return err
						}
						data, err = json.Marshal(items)
						return err
					})
					if err != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_HISTORY_ERROR "+base64.RawURLEncoding.EncodeToString([]byte(err.Error())))
					} else {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_HISTORY "+base64.RawURLEncoding.EncodeToString(data))
					}
					continue
				}
				if strings.HasPrefix(command, "backup inventory ") {
					if inventoryActive {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR backup_inventory_already_running")
						continue
					}
					raw, decodeErr := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(command, "backup inventory "))
					if decodeErr != nil || len(raw) == 0 || len(raw) >= 4096 {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR invalid_backup_location_or_manifest")
						continue
					}
					inventoryActive = true
					go func(destination string) {
						scanCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
						defer cancel()
						inventory, err := backupService.ListSnapshots(scanCtx, destination)
						select {
						case inventoryDone <- inventoryResult{inventory: inventory, err: err}:
						case <-ctx.Done():
						}
					}(string(raw))
					continue
				}
				if command == "export cancel" {
					if exportCancel != nil {
						exportCancel()
					}
					continue
				}
				if strings.HasPrefix(command, "export start ") {
					if exportCancel != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_ERROR "+base64.RawURLEncoding.EncodeToString([]byte("export_already_running")))
						continue
					}
					raw, e := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(command, "export start "))
					var request struct {
						Source      string `json:"source"`
						Destination string `json:"destination"`
						Mode        string `json:"mode"`
					}
					if e != nil || len(raw) > 8192 || json.Unmarshal(raw, &request) != nil || request.Source == "" || request.Destination == "" || (request.Mode != "" && request.Mode != "copy" && request.Mode != "move") {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_ERROR "+base64.RawURLEncoding.EncodeToString([]byte("invalid_export_request")))
						continue
					}
					if request.Mode == "move" && nativeMoveTouchesPersonalHome(request.Source) {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_ERROR "+base64.RawURLEncoding.EncodeToString([]byte("personal_move_accounting_pending_use_copy")))
						continue
					}
					registeredPaths := make([]string, 0)
					for _, root := range rootRegistry.List() {
						registeredPaths = append(registeredPaths, root.Path)
					}
					if nativeExportOverlapsRegisteredRoot(request.Destination, registeredPaths) {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_ERROR "+base64.RawURLEncoding.EncodeToString([]byte("export_destination_is_a_managed_nas_root")))
						continue
					}
					job, cancel := context.WithCancel(ctx)
					if err := diskmgmt.WithStorageTransition(func() error {
						externalTransferRunning.Store(true)
						return nil
					}); err != nil {
						cancel()
						fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_ERROR "+base64.RawURLEncoding.EncodeToString([]byte(err.Error())))
						continue
					}
					exportCancel = cancel
					fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_STARTED")
					go func() {
						defer cancel()
						var path string
						var err error
						err = withDefaultManager(job, rootRegistry, rootServer, func(manager *files.Manager) error {
							if request.Mode == "move" {
								receipt, transferErr := manager.MoveOut(job, request.Source, request.Destination)
								path = receipt.Destination
								return transferErr
							}
							var transferErr error
							path, transferErr = manager.CopyOut(job, request.Source, request.Destination)
							return transferErr
						})
						select {
						case exportDone <- exportResult{path: path, err: err}:
						case <-ctx.Done():
						}
					}()
					continue
				}
				if command == "index scan" {
					reconciler.Request()
					continue
				}
				if command == "backup cancel" {
					if backupService.Cancel() {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_CANCEL_REQUESTED")
					} else {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR task_not_running")
					}
					continue
				}
				if strings.HasPrefix(command, "admin reset ") {
					// Only the parent Mac UI writes this pipe after owner
					// authentication. This parser does not grant authorization.
					password, valid := parseNativeAdminPassword(strings.TrimPrefix(command, "admin reset "))
					if !valid {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_RESET_ERROR invalid_request")
						continue
					}
					username, err := accountStore.ResetFirstAdminPassword(password)
					switch {
					case err == nil:
						fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_RESET_OK "+base64.RawURLEncoding.EncodeToString([]byte(username)))
					case errors.Is(err, auth.ErrInput):
						fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_RESET_ERROR invalid_password")
					case errors.Is(err, auth.ErrNotFound):
						fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_RESET_ERROR admin_missing")
					default:
						slog.Error("native administrator password reset failed", "error", err)
						fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_RESET_ERROR internal_error")
					}
					continue
				}
				if strings.HasPrefix(command, "admin verify ") {
					credentials, valid := parseNativeAdminCredentials(strings.TrimPrefix(command, "admin verify "))
					if !valid {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_VERIFY_FAILED")
						continue
					}
					if accountStore.VerifyAdministrator(credentials.Username, credentials.Password) {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_VERIFIED")
						continue
					}
					fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_VERIFY_FAILED")
					continue
				}
				if command == "backup schedule status" {
					payload, _ := json.Marshal(backupSchedule.Status())
					fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_SCHEDULE "+base64.RawURLEncoding.EncodeToString(payload))
					continue
				}
				if command == "backup schedule off" {
					if err := backupSchedule.Disable(); err != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR "+err.Error())
					} else {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_SCHEDULE_CHANGED")
					}
					continue
				}
				if strings.HasPrefix(command, "backup schedule set ") {
					parts := strings.Fields(strings.TrimPrefix(command, "backup schedule set "))
					if len(parts) != 4 {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR invalid_schedule")
						continue
					}
					hours, e := strconv.Atoi(parts[0])
					retentionCount := 0
					encodedPath := parts[len(parts)-1]
					if e == nil {
						retentionCount, e = strconv.Atoi(parts[1])
					}
					metadataOnly := parts[2] == backup.MetadataBackupType
					if !metadataOnly || hours != 168 || retentionCount != 5 {
						e = backup.ErrInvalid
					}
					var data []byte
					if e == nil {
						data, e = base64.RawURLEncoding.DecodeString(encodedPath)
					}
					if e == nil && len(data) > 0 && len(data) < 4096 {
						e = backupSchedule.ConfigureMetadataWeekly(string(data), retentionCount)
					} else if e == nil {
						e = backup.ErrInvalid
					}
					if e != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR "+e.Error())
					} else {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_SCHEDULE_CHANGED")
					}
					continue
				}
				if command == "backup status" {
					data, err := json.Marshal(backupService.Status())
					if err == nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_STATUS "+base64.RawURLEncoding.EncodeToString(data))
					}
					continue
				}
				if strings.HasPrefix(command, "backup start ") {
					fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR full_file_backup_not_supported")
					continue
				}
				if strings.HasPrefix(command, "backup metadata start ") || strings.HasPrefix(command, "backup restore ") {
					kind := "backup start "
					if strings.HasPrefix(command, "backup metadata start ") {
						kind = "backup metadata start "
					}
					if strings.HasPrefix(command, "backup restore ") {
						kind = "backup restore "
					}
					raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(command, kind))
					if err == nil && len(raw) > 0 && len(raw) < 4096 {
						if kind == "backup metadata start " {
							err = backupService.StartMetadataBackup(string(raw))
						} else {
							err = backupService.StartMetadataRestore(string(raw))
						}
					} else {
						err = backup.ErrInvalid
					}
					if err != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR "+err.Error())
					} else {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_STARTED")
					}
					continue
				}
				if command == "smb status" {
					conn, err := net.DialTimeout("tcp4", "127.0.0.1:445", 250*time.Millisecond)
					if err != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SMB_STATUS 0")
					} else {
						conn.Close()
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SMB_STATUS 1")
					}
					continue
				}
				if command == "stats" || command == "stats summary" {
					// Hidden-window health checks do not need a process list.
					var reading any
					var err error
					if command == "stats summary" {
						reading, err = monitor.Collect()
					} else {
						reading, err = monitor.CollectLocal()
					}
					if err != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_STATS_ERROR")
						continue
					}
					payload, err := json.Marshal(reading)
					if err == nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_STATS "+base64.RawURLEncoding.EncodeToString(payload))
					}
					continue
				}
				if strings.HasPrefix(command, "admin init ") {
					credentials, valid := parseNativeAdminCredentials(strings.TrimPrefix(command, "admin init "))
					if !valid {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_INIT_ERROR invalid_request")
						continue
					}
					err = accountStore.Setup(credentials.Username, credentials.Password)
					switch {
					case err == nil:
						fmt.Fprintln(os.Stdout, "LIGHTISLE_INITIALIZED")
						fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_ACCOUNT "+base64.RawURLEncoding.EncodeToString([]byte(credentials.Username)))
					case errors.Is(err, auth.ErrExists):
						fmt.Fprintln(os.Stdout, "LIGHTISLE_INIT_ERROR already_configured")
					case errors.Is(err, auth.ErrInput):
						fmt.Fprintln(os.Stdout, "LIGHTISLE_INIT_ERROR invalid_credentials")
					default:
						slog.Error("native initialization failed", "error", err)
						fmt.Fprintln(os.Stdout, "LIGHTISLE_INIT_ERROR internal_error")
					}
					continue
				}
				// Retired path-only mutation commands are intentionally not able
				// to change the active NAS root or resurrect abandoned metadata.
				if strings.HasPrefix(command, "share set ") || strings.HasPrefix(command, "share forget ") {
					fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ERROR root_registry_only")
					continue
				}
				if command == "share retry" {
					selected, configured := rootRegistry.Default()
					if !configured {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ERROR default_root_not_configured")
						continue
					}
					if _, online := registeredDefaultState(rootRegistry); !online {
						if _, err := rootRegistry.Rebind(ctx, selected.ID, selected.Path); err != nil {
							fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ERROR "+err.Error())
							continue
						}
					}
					reconciler.Request()
					fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ON "+filepath.Base(selected.Path))
					fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_PATH "+base64.RawURLEncoding.EncodeToString([]byte(selected.Path)))
					continue
				}
				if command == "remote off" {
					if remote != nil {
						remote.Stop()
						remote = nil
					}
					fmt.Fprintln(os.Stdout, "LIGHTISLE_REMOTE_OFF")
				} else if remote == nil || (command == "remote http on") != strings.HasPrefix(remote.URL, "http://") {
					if remote != nil {
						remote.Stop()
						remote = nil
						fmt.Fprintln(os.Stdout, "LIGHTISLE_REMOTE_OFF")
					}
					var next *server.Remote
					var err error
					if command == "remote http on" {
						next, err = server.NewRemoteHTTP(handler, accountStore, *port)
					} else {
						next, err = server.NewRemote(handler, accountStore, *dataDir, *port)
					}
					if err != nil {
						slog.Warn("remote activation refused", "error", err)
						fmt.Fprintln(os.Stdout, "LIGHTISLE_REMOTE_ERROR "+err.Error())
						continue
					}
					remote = next
					fingerprint := remote.Fingerprint
					if fingerprint == "" {
						fingerprint = "-"
					}
					fmt.Fprintf(os.Stdout, "LIGHTISLE_REMOTE_ON %s %s\n", remote.URL, fingerprint)
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

	fmt.Fprintf(os.Stdout, "LIGHTISLE_READY http://%s\n", listener.Addr().String())
	configured, configurationError := accountStore.Configured()
	if configurationError == nil {
		if configured {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_CONFIGURED 1")
		} else {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_CONFIGURED 0")
		}
	}
	selectedRoot, shareOnline := registeredDefaultState(rootRegistry)
	if selectedRoot == "" {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ON unconfigured")
	} else {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ON "+filepath.Base(selectedRoot))
	}
	if configured {
		if username, err := accountStore.FirstAdminUsername(); err == nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_ACCOUNT "+base64.RawURLEncoding.EncodeToString([]byte(username)))
		}
	}
	if shareOnline {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_PATH "+base64.RawURLEncoding.EncodeToString([]byte(selectedRoot)))
	}
	if !shareOnline {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ERROR 共享卷当前未挂载，请在设置中重新连接")
		fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_OFFLINE_PATH "+base64.RawURLEncoding.EncodeToString([]byte(selectedRoot)))
	}
	if err := httpServer.Serve(listener); err != nil && err != http.ErrServerClosed {
		slog.Error("HTTP server failure", "error", err)
		os.Exit(1)
	}
}
