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
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/backup"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
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
	processLock, err := backup.LockDataDir(*dataDir)
	if err != nil {
		slog.Error("data directory is already in use", "error", err)
		os.Exit(1)
	}
	defer processLock.Close()
	if backup.RecoveryPending(*dataDir) {
		slog.Error("offline metadata recovery was interrupted; refuse to start with partially migrated state")
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
	taskJournal, err := tasks.Open(*dataDir)
	if err != nil {
		slog.Error("cannot initialize durable task journal", "error", err)
		os.Exit(1)
	}
	defer taskJournal.Close()
	photoLibrary, err := gallery.OpenWithOptions(*dataDir, fileStore, gallery.Options{ThumbnailCacheBytes: *thumbnailCacheBytes})
	if err != nil {
		slog.Error("cannot initialize photo library", "error", err)
		os.Exit(1)
	}
	defer photoLibrary.Close()
	photoLibrary.SetJournal(taskJournal)
	filmLibrary, err := cinema.Open(*dataDir, fileStore)
	if err != nil {
		slog.Error("cannot initialize cinema library", "error", err)
		os.Exit(1)
	}
	defer filmLibrary.Close()
	filmLibrary.SetJournal(taskJournal)
	backupService := backup.New(fileStore, *dataDir)
	defer backupService.Close()
	backupService.SetJournal(taskJournal)
	backupSchedule, err := backup.NewScheduler(backupService, *dataDir)
	if err != nil {
		slog.Error("cannot initialize backup schedule", "error", err)
		os.Exit(1)
	}
	defer backupSchedule.Close()
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
	handler := server.NewWithJournal(*webRoot, accountStore, fileStore, photoLibrary, filmLibrary, taskJournal, backupService)
	httpServer := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// Reconcile external filesystem changes periodically while the Mac App is
	// running. No independent daemon is installed, and jobs stop on App exit.
	go func() {
		ticker := time.NewTicker(15 * time.Minute)
		initial := time.NewTimer(30 * time.Second)
		defer ticker.Stop()
		defer initial.Stop()
		reconcile := func() {
			if _, online := fileStore.State(); !online {
				return
			}
			_ = photoLibrary.StartScan()
			_ = filmLibrary.StartScan()
		}
		for {
			select {
			case <-ctx.Done():
				return
			case <-initial.C:
				reconcile()
			case <-ticker.C:
				reconcile()
			}
		}
	}()

	var remote *server.Remote
	// Only the trusted Mac App stdin pipe can request remote activation.
	// Remote access is never enabled by default or via a public HTTP endpoint.
	control := make(chan string, 8)
	if !*standalone {
		// The Swift App owns the write end of stdin; EOF means App exited or crashed.
		go func() {
			s := bufio.NewScanner(os.Stdin)
			s.Buffer(make([]byte, 4096), 8192)
			for s.Scan() {
				command := strings.TrimSpace(s.Text())
				if command == "shutdown" {
					break
				}
				if command == "remote on" || command == "remote off" || strings.HasPrefix(command, "share set ") || command == "share retry" || command == "index scan" || strings.HasPrefix(command, "admin init ") || strings.HasPrefix(command, "admin verify ") || strings.HasPrefix(command, "admin reset ") || command == "stats" || command == "backup status" || command == "backup cancel" || strings.HasPrefix(command, "backup start ") || strings.HasPrefix(command, "backup restore ") || command == "smb status" || command == "backup schedule status" || command == "backup schedule off" || strings.HasPrefix(command, "backup schedule set ") || strings.HasPrefix(command, "export start ") || command == "export cancel" {
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
	var exportCancel context.CancelFunc
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
				if result.err != nil {
					fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_ERROR "+base64.RawURLEncoding.EncodeToString([]byte(result.err.Error())))
				} else {
					fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_OK "+base64.RawURLEncoding.EncodeToString([]byte(result.path)))
				}
			case command := <-control:
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
					}
					if e != nil || len(raw) > 8192 || json.Unmarshal(raw, &request) != nil || request.Source == "" || request.Destination == "" {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_ERROR "+base64.RawURLEncoding.EncodeToString([]byte("invalid_export_request")))
						continue
					}
					job, cancel := context.WithCancel(ctx)
					exportCancel = cancel
					fmt.Fprintln(os.Stdout, "LIGHTISLE_EXPORT_STARTED")
					go func() {
						defer cancel()
						path, err := fileStore.CopyOut(job, request.Source, request.Destination)
						select {
						case exportDone <- exportResult{path: path, err: err}:
						case <-ctx.Done():
						}
					}()
					continue
				}
				if command == "index scan" {
					if _, online := fileStore.State(); online {
						_ = photoLibrary.StartScan()
						_ = filmLibrary.StartScan()
					}
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
					parts := strings.SplitN(strings.TrimPrefix(command, "backup schedule set "), " ", 2)
					if len(parts) != 2 {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_BACKUP_ERROR invalid_schedule")
						continue
					}
					hours, e := strconv.Atoi(parts[0])
					var data []byte
					if e == nil {
						data, e = base64.RawURLEncoding.DecodeString(parts[1])
					}
					if e == nil && len(data) > 0 && len(data) < 4096 {
						e = backupSchedule.Configure(string(data), hours)
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
					reading, err := monitor.Collect()
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
					encoded := strings.TrimPrefix(command, "share set ")
					decoded, err := base64.RawURLEncoding.DecodeString(encoded)
					if err == nil {
						err = fileStore.SetRoot(string(decoded))
					}
					if err != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ERROR "+err.Error())
					} else {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ON "+fileStore.DisplayName())
						selected, _ := fileStore.State()
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_PATH "+base64.RawURLEncoding.EncodeToString([]byte(selected)))
					}
					continue
				}
				if command == "share retry" {
					if err := fileStore.Reconnect(); err != nil {
						fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ERROR "+err.Error())
					} else {
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
	}
	if err := httpServer.Serve(listener); err != nil && err != http.ErrServerClosed {
		slog.Error("HTTP server failure", "error", err)
		os.Exit(1)
	}
}
