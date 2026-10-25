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

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/backup"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/diskhealth"
	"github.com/lengsukq/lightisle/core/internal/diskmgmt"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
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
	multiRootPreview := flag.Bool("multi-root-preview", false, "developer-only: enable root-scoped API while client/backup acceptance is pending")
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
	fileStore, err := files.NewManager(*dataDir)
	if err != nil {
		slog.Error("cannot initialize shared folder", "error", err)
		os.Exit(1)
	}
	defer fileStore.Close()
	// Safely migrate the old path-only share to an OFFLINE rootID record.
	// Do not expose multi-root HTTP routes until files/media/uploads/shares
	// all enforce scoped permissions and leases. A malformed new registry
	// must never silently fall back to a different volume.
	rootRegistry, err := roots.Open(*dataDir)
	if err != nil {
		slog.Error("cannot initialize physical shared root registry", "error", err)
		os.Exit(1)
	}
	taskJournal, err := tasks.Open(*dataDir)
	if err != nil {
		slog.Error("cannot initialize durable task journal", "error", err)
		os.Exit(1)
	}
	defer taskJournal.Close()
	alertThresholds := tasks.OpenThresholdStore(filepath.Join(*dataDir, "storage-alerts.json"))
	trashRetention := tasks.OpenRetentionStore(filepath.Join(*dataDir, "trash-retention.json"))
	photoLibrary, err := gallery.OpenWithOptions(*dataDir, fileStore, gallery.Options{ThumbnailCacheBytes: *thumbnailCacheBytes})
	if err != nil {
		slog.Error("cannot initialize photo library", "error", err)
		os.Exit(1)
	}
	defer photoLibrary.Close()
	photoLibrary.SetJournal(taskJournal)
	mediaWorker := mediaworker.New(*mediaWorkerPath)
	photoLibrary.SetMediaWorker(mediaWorker)
	filmLibrary, err := cinema.Open(*dataDir, fileStore)
	if err != nil {
		slog.Error("cannot initialize cinema library", "error", err)
		os.Exit(1)
	}
	defer filmLibrary.Close()
	filmLibrary.SetJournal(taskJournal)
	filmLibrary.SetMediaWorker(mediaWorker)
	backupService := backup.New(fileStore, *dataDir)
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
		if externalTransferRunning.Load() || backupService.Status().Running || photoLibrary.Status().Running || filmLibrary.Status().Running {
			return diskmgmt.ErrBusy
		}
		if action == "mount" {
			return nil
		}
		paths := []string{}
		selected, _ := fileStore.State()
		paths = append(paths, selected)
		if binding, ok := fileStore.RootBinding(); ok && diskmgmt.MatchesVolumeUUID(d, binding.VolumeUUID) {
			return diskmgmt.ErrProtected
		}
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
	var handler http.Handler = server.NewWithRetention(*webRoot, accountStore, fileStore, photoLibrary, filmLibrary, taskJournal, trashRetention, backupService)
	var rootServer *server.RootServer
	if *multiRootPreview {
		rootServer = server.NewWithRoots(*webRoot, accountStore, fileStore, photoLibrary, filmLibrary, taskJournal, rootRegistry,
			makeRootServices(*dataDir, mediaWorker, *thumbnailCacheBytes, rootRegistry), server.RootServerOptions{
				EnableDiscovery: true, LegacyBackup: backupService, TrashRetention: trashRetention,
			})
		handler = rootServer
		defer rootServer.Close()
	}
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
	go monitorAlerts(ctx, fileStore, taskJournal, alertThresholds, accountStore)
	go monitorMetricHistory(ctx, taskJournal)
	startTrashSweeper(ctx, fileStore, trashRetention, taskJournal)
	if *multiRootPreview && rootServer != nil {
		// The original shared folder keeps its existing FSEvents watcher.
		// Additional roots only reconcile under the explicit developer preview.
		// No automatic backup is started without an owner-chosen destination.
		go newRootMediaMaintenance(rootRegistry, rootServer, taskJournal).Run(ctx)
	}
	// A burst of FSEvents must never trigger overlapping full scans or drop
	// a change because one of the media libraries is already scanning.
	startPhoto := func() bool {
		if _, online := fileStore.State(); !online {
			return false
		}
		return errors.Is(photoLibrary.StartScan(), gallery.ErrBusy)
	}
	startFilm := func() bool {
		if _, online := fileStore.State(); !online {
			return false
		}
		return errors.Is(filmLibrary.StartScan(), cinema.ErrScanning)
	}
	reconciler := newMediaReconciler(startPhoto, startFilm)
	go reconciler.Run(ctx)

	var remote *server.Remote
	// Only the trusted Mac App stdin pipe can request remote activation.
	// Remote access is never enabled by default or via a public HTTP endpoint.
	control := make(chan string, 8)
	rootCommands := &rootControl{output: os.Stdout}
	defer rootCommands.Close()
	tunnelCtl := newTunnelControl(ctx, *port, func(code string, active bool) {
		if err := taskJournal.SyncAlert(code, active); err != nil {
			slog.Warn("tunnel status alert was not persisted", "code", code, "active", active, "error", err)
		}
	})
	if *multiRootPreview {
		rootCommands.registry = rootRegistry
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
				if strings.HasPrefix(command, "roots ") || command == "remote on" || command == "remote off" || strings.HasPrefix(command, "share set ") || strings.HasPrefix(command, "share forget ") || command == "share retry" || command == "share status" || command == "disk list" || strings.HasPrefix(command, "disk action ") || strings.HasPrefix(command, "disk smart ") || command == "index scan" || strings.HasPrefix(command, "index dirs ") || strings.HasPrefix(command, "admin init ") || strings.HasPrefix(command, "admin verify ") || strings.HasPrefix(command, "admin reset ") || command == "stats" || command == "alerts status" || command == "alerts threshold" || strings.HasPrefix(command, "alerts threshold ") || command == "backup status" || command == "backup cancel" || strings.HasPrefix(command, "backup start ") || strings.HasPrefix(command, "backup restore ") || strings.HasPrefix(command, "backup inventory ") || command == "smb status" || command == "backup schedule status" || command == "backup schedule off" || strings.HasPrefix(command, "backup schedule set ") || strings.HasPrefix(command, "export start ") || command == "export cancel" || command == "export history" || strings.HasPrefix(command, "tunnel ") || strings.HasPrefix(command, "cinema tmdb ") || strings.HasPrefix(command, "trash ") {
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
				if rootCommands.handle(ctx, command) {
					continue
				}
				if tunnelCtl.handle(ctx, command) {
					continue
				}
				if command == "disk list" {
					disks, err := diskmgmt.Shared().List(ctx)
					if err != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_DISKS_ERROR "+err.Error())
					} else if data, err := json.Marshal(disks); err == nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_DISKS "+base64.RawURLEncoding.EncodeToString(data))
					}
					continue
				}
				if strings.HasPrefix(command, "disk action ") {
					raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(command, "disk action "))
					var request diskmgmt.Request
					if err != nil || len(raw) == 0 || len(raw) > 2048 || json.Unmarshal(raw, &request) != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_DISKS_ERROR invalid_drive_request")
						continue
					}
					disks, err := diskmgmt.Shared().Do(ctx, request)
					if err != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_DISKS_ERROR "+err.Error())
					} else if data, err := json.Marshal(disks); err == nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_DISKS "+base64.RawURLEncoding.EncodeToString(data))
					}
					continue
				}
				if strings.HasPrefix(command, "disk smart ") {
					id := strings.TrimPrefix(command, "disk smart ")
					if strings.HasPrefix(id, "report ") {
						// Trusted Mac App pushed a user-authorized elevated
						// SMART result; cache it so the Web view benefits too.
						raw, decodeErr := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(id, "report "))
						var request struct {
							Device string          `json:"device"`
							Report json.RawMessage `json:"report"`
						}
						if decodeErr != nil || len(raw) == 0 || len(raw) > 76800 || json.Unmarshal(raw, &request) != nil {
							fmt.Fprintln(os.Stdout, "LIGHTISLE_DISKS_ERROR invalid_drive_request")
							continue
						}
						report, err := diskhealth.Shared().IngestReport(request.Device, request.Report)
						if err != nil {
							fmt.Fprintln(os.Stdout, "LIGHTISLE_DISKS_ERROR invalid_drive_request")
							continue
						}
						if data, err := json.Marshal(report); err == nil {
							fmt.Fprintln(os.Stdout, "LIGHTISLE_DISK_SMART "+base64.RawURLEncoding.EncodeToString(data))
						}
						continue
					}
					report, err := diskhealth.Shared().Report(ctx, id)
					if err != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_DISKS_ERROR invalid_drive_request")
					} else if data, err := json.Marshal(report); err == nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_DISK_SMART "+base64.RawURLEncoding.EncodeToString(data))
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
					if _, online := fileStore.State(); !online {
						continue
					}
					// Invalid scopes are rejected by each library. Busy scoped scans
					// enqueue an eventual full retry so no changed event is lost.
					photoErr := photoLibrary.StartScanDirs(dirs)
					filmErr := filmLibrary.StartScanDirs(dirs)
					if errors.Is(photoErr, gallery.ErrBusy) || errors.Is(filmErr, cinema.ErrScanning) {
						reconciler.Request()
					}
					continue
				}
				if command == "share status" {
					// A read-only physical identity check, not a reconnect. The
					// native menu-bar app uses it to detect a disk unplugged while
					// nobody has an HTTP file-management page open.
					path, online := fileStore.State()
					if online {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_STATUS 1")
					} else {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_STATUS 0")
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_OFFLINE_PATH "+base64.RawURLEncoding.EncodeToString([]byte(path)))
					}
					continue
				}
				if command == "alerts status" {
					alerts, err := taskJournal.Alerts(true)
					if err != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_ALERTS_ERROR")
					} else if payload, err := json.Marshal(alerts); err == nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_ALERTS "+base64.RawURLEncoding.EncodeToString(payload))
					}
					continue
				}
				if command == "alerts threshold" || strings.HasPrefix(command, "alerts threshold ") {
					if encoded := strings.TrimPrefix(command, "alerts threshold"); strings.TrimSpace(encoded) != "" {
						raw, decodeErr := base64.RawURLEncoding.DecodeString(strings.TrimSpace(encoded))
						var request tasks.Threshold
						if decodeErr != nil || len(raw) == 0 || len(raw) > 256 || json.Unmarshal(raw, &request) != nil {
							fmt.Fprintln(os.Stdout, "LIGHTISLE_ALERTS_THRESHOLD_ERROR invalid_storage_threshold")
							continue
						}
						if _, err := alertThresholds.Set(request); err != nil {
							fmt.Fprintln(os.Stdout, "LIGHTISLE_ALERTS_THRESHOLD_ERROR "+err.Error())
							continue
						}
					}
					if payload, err := json.Marshal(alertThresholds.Get()); err == nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_ALERTS_THRESHOLD "+base64.RawURLEncoding.EncodeToString(payload))
					}
					continue
				}
				// The TMDB Read Access Token arrives only from the trusted Mac
				// App (Keychain storage) and stays in Core memory; it is never
				// persisted, logged or echoed back.
				// Trash auto-cleanup is opt-in and only settable by the Mac
				// App; Web/Flutter get a read-only HTTP view.
				if strings.HasPrefix(command, "trash retention") {
					if encoded := strings.TrimPrefix(command, "trash retention"); strings.TrimSpace(encoded) != "" {
						raw, decodeErr := base64.RawURLEncoding.DecodeString(strings.TrimSpace(encoded))
						var request tasks.Retention
						if decodeErr != nil || len(raw) == 0 || len(raw) > 256 || json.Unmarshal(raw, &request) != nil {
							fmt.Fprintln(os.Stdout, "LIGHTISLE_TRASH_RETENTION_ERROR invalid_trash_retention")
							continue
						}
						if !request.Enabled && request.Days != 0 {
							fmt.Fprintln(os.Stdout, "LIGHTISLE_TRASH_RETENTION_ERROR invalid_trash_retention")
							continue
						}
						if request.Enabled && (request.Days < tasks.MinRetentionDays || request.Days > tasks.MaxRetentionDays) {
							fmt.Fprintln(os.Stdout, "LIGHTISLE_TRASH_RETENTION_ERROR invalid_trash_retention")
							continue
						}
						if _, err := trashRetention.Set(request); err != nil {
							fmt.Fprintln(os.Stdout, "LIGHTISLE_TRASH_RETENTION_ERROR "+err.Error())
							continue
						}
					}
					if payload, err := json.Marshal(trashRetention.Get()); err == nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_TRASH_RETENTION "+base64.RawURLEncoding.EncodeToString(payload))
					}
					continue
				}
				if strings.HasPrefix(command, "cinema tmdb ") {
					switch {
					case strings.HasPrefix(command, "cinema tmdb set "):
						raw, decodeErr := base64.RawURLEncoding.DecodeString(strings.TrimSpace(strings.TrimPrefix(command, "cinema tmdb set ")))
						if decodeErr != nil || filmLibrary.SetTMDBToken(string(raw)) != nil {
							fmt.Fprintln(os.Stdout, "LIGHTISLE_TMDB_ERROR invalid_tmdb_token")
							continue
						}
					case command == "cinema tmdb clear":
						filmLibrary.ClearTMDBToken()
					}
					if payload, err := json.Marshal(map[string]bool{"configured": filmLibrary.TMDBTokenConfigured()}); err == nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_TMDB_STATE "+base64.RawURLEncoding.EncodeToString(payload))
					}
					continue
				}
				if command == "export history" {
					items, err := fileStore.ListTransfers()
					if err != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_HISTORY_ERROR "+base64.RawURLEncoding.EncodeToString([]byte(err.Error())))
					} else if data, err := json.Marshal(items); err == nil {
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
						if request.Mode == "move" {
							var receipt files.TransferReceipt
							receipt, err = fileStore.MoveOut(job, request.Source, request.Destination)
							path = receipt.Destination
						} else {
							path, err = fileStore.CopyOut(job, request.Source, request.Destination)
						}
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
					// Only the parent Mac UI writes this pipe; Swift first calls
					// LocalAuthentication.deviceOwnerAuthentication. No HTTP
					// endpoint can invoke this recovery operation.
					raw, decodeErr := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(command, "admin reset "))
					if decodeErr != nil || len(raw) > 2048 {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_RESET_ERROR invalid_request")
						continue
					}
					var request struct {
						Password string `json:"password"`
					}
					if json.Unmarshal(raw, &request) != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_RESET_ERROR invalid_request")
						continue
					}
					username, err := accountStore.ResetFirstAdminPassword(request.Password)
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
					raw, decodeErr := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(command, "admin verify "))
					if decodeErr != nil || len(raw) > 2048 {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_VERIFY_FAILED")
						continue
					}
					var credentials struct {
						Username string `json:"username"`
						Password string `json:"password"`
					}
					if json.Unmarshal(raw, &credentials) != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_VERIFY_FAILED")
						continue
					}
					session, loginErr := accountStore.Login(credentials.Username, credentials.Password)
					if loginErr == nil {
						user, verified := accountStore.Identity(session)
						accountStore.Logout(session)
						if verified && user.Role == auth.RoleAdmin {
							fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_VERIFIED")
							continue
						}
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
					if len(parts) != 2 && len(parts) != 3 {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR invalid_schedule")
						continue
					}
					hours, e := strconv.Atoi(parts[0])
					retentionCount := 0
					encodedPath := parts[len(parts)-1]
					if e == nil && len(parts) == 3 {
						retentionCount, e = strconv.Atoi(parts[1])
					}
					var data []byte
					if e == nil {
						data, e = base64.RawURLEncoding.DecodeString(encodedPath)
					}
					if e == nil && len(data) > 0 && len(data) < 4096 {
						e = backupSchedule.ConfigureWithRetention(string(data), hours, retentionCount)
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
				if strings.HasPrefix(command, "backup start ") || strings.HasPrefix(command, "backup restore ") {
					kind := "backup start "
					if strings.HasPrefix(command, "backup restore ") {
						kind = "backup restore "
					}
					raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(command, kind))
					if err == nil && len(raw) > 0 && len(raw) < 4096 {
						if kind == "backup start " {
							err = backupService.StartBackup(string(raw))
						} else {
							err = backupService.StartRestore(string(raw))
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
				if command == "stats" {
					reading, err := monitor.CollectLocal()
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
					raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(command, "admin init "))
					if err != nil || len(raw) > 2048 {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_INIT_ERROR invalid_request")
						continue
					}
					var credentials struct {
						Username string `json:"username"`
						Password string `json:"password"`
					}
					if err := json.Unmarshal(raw, &credentials); err != nil {
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
				if strings.HasPrefix(command, "share set ") {
					if *multiRootPreview {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ERROR 多目录预览期间保留原共享目录；请退出预览后修改原目录")
						continue
					}
					encoded := strings.TrimPrefix(command, "share set ")
					decoded, err := base64.RawURLEncoding.DecodeString(encoded)
					if err == nil {
						err = diskmgmt.WithStorageTransition(func() error {
							if externalTransferRunning.Load() || backupService.Status().Running || photoLibrary.Status().Running || filmLibrary.Status().Running {
								return diskmgmt.ErrBusy
							}
							return fileStore.SetRoot(string(decoded))
						})
					}
					if err != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ERROR "+err.Error())
					} else {
						requestMediaReconciliationAfterShareOnline(reconciler)
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ON "+fileStore.DisplayName())
						selected, _ := fileStore.State()
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_PATH "+base64.RawURLEncoding.EncodeToString([]byte(selected)))
					}
					continue
				}
				if strings.HasPrefix(command, "share forget ") {
					old, online := fileStore.State()
					claimed, decodeErr := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(command, "share forget "))
					if *multiRootPreview || decodeErr != nil || len(claimed) == 0 || len(claimed) > 4096 ||
						string(claimed) != old || online || exportCancel != nil || backupService.Status().Running ||
						photoLibrary.Status().Running || filmLibrary.Status().Running {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_FORGET_ERROR offline_share_not_eligible_or_busy")
						continue
					}
					var forgotten string
					if err := diskmgmt.WithStorageTransition(func() error {
						var transitionErr error
						forgotten, transitionErr = fileStore.ForgetOfflineRoot()
						return transitionErr
					}); err != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_FORGET_ERROR "+err.Error())
						continue
					}
					fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_FORGOT "+base64.RawURLEncoding.EncodeToString([]byte(forgotten)))
					// No file IO occurs on the disconnected volume. Local derived
					// metadata is deleted only for the exact old physical share.
					if galleryErr := photoLibrary.ForgetLegacyShare(forgotten); galleryErr != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_FORGET_WARNING "+galleryErr.Error())
					}
					if cinemaErr := filmLibrary.ForgetLegacyShare(forgotten); cinemaErr != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_FORGET_WARNING "+cinemaErr.Error())
					}
					if accessErr := accountStore.ForgetLegacyShareAccess(); accessErr != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_FORGET_WARNING "+accessErr.Error())
					}
					for _, registered := range rootRegistry.List() {
						if !registered.Compatibility || registered.Path != forgotten {
							continue
						}
						if err := accountStore.ForgetRootAccess(registered.ID); err != nil {
							fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_FORGET_WARNING "+err.Error())
							continue
						}
						if err := rootRegistry.Remove(registered.ID); err != nil {
							fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_FORGET_WARNING "+err.Error())
						}
					}
					requestMediaReconciliationAfterShareOnline(reconciler)
					fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ON "+fileStore.DisplayName())
					selected, _ := fileStore.State()
					fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_PATH "+base64.RawURLEncoding.EncodeToString([]byte(selected)))
					continue
				}
				if command == "share retry" {
					if err := fileStore.Reconnect(); err != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ERROR "+err.Error())
					} else {
						requestMediaReconciliationAfterShareOnline(reconciler)
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ON "+fileStore.DisplayName())
						selected, _ := fileStore.State()
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_PATH "+base64.RawURLEncoding.EncodeToString([]byte(selected)))
					}
					continue
				}
				if command == "remote off" {
					if remote != nil {
						remote.Stop()
						remote = nil
					}
					fmt.Fprintln(os.Stdout, "LIGHTISLE_REMOTE_OFF")
				} else if remote == nil {
					next, err := server.NewRemote(handler, accountStore, *dataDir)
					if err != nil {
						slog.Warn("remote activation refused", "error", err)
						fmt.Fprintln(os.Stdout, "LIGHTISLE_REMOTE_ERROR "+err.Error())
						continue
					}
					remote = next
					fmt.Fprintf(os.Stdout, "LIGHTISLE_REMOTE_ON %s %s\n", remote.URL, remote.Fingerprint)
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
	selectedRoot, shareOnline := fileStore.State()
	fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ON "+filepath.Base(selectedRoot))
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
