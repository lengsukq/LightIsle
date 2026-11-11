//go:build darwin && arm64

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"path/filepath"
	"strings"
	"sync/atomic"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
	"github.com/lengsukq/lightisle/core/internal/system"
)

func isAcceptedIPCCommand(command string) bool {
	return strings.HasPrefix(command, "roots ") ||
		command == "computer-files status" || command == "computer-files on" || command == "computer-files off" ||
		command == "diagnostics debug" ||
		command == "spaces" || strings.HasPrefix(command, "spaces ") ||
		command == "apps" || strings.HasPrefix(command, "apps ") ||
		command == "remote on" || command == "remote http on" || command == "remote off" ||
		strings.HasPrefix(command, "share set ") || strings.HasPrefix(command, "share forget ") ||
		command == "share retry" || command == "share status" ||
		command == "disk list" || strings.HasPrefix(command, "disk action ") || strings.HasPrefix(command, "disk smart ") ||
		command == "index scan" || strings.HasPrefix(command, "index dirs ") || strings.HasPrefix(command, "index root ") ||
		strings.HasPrefix(command, "admin init ") || strings.HasPrefix(command, "admin verify ") || strings.HasPrefix(command, "admin reset ") ||
		command == "stats" || command == "stats summary" ||
		command == "alerts status" || command == "alerts threshold" || strings.HasPrefix(command, "alerts threshold ") ||
		command == "backup status" || command == "backup cancel" ||
		strings.HasPrefix(command, "backup start ") || strings.HasPrefix(command, "backup metadata start ") ||
		strings.HasPrefix(command, "backup restore ") || strings.HasPrefix(command, "backup inventory ") ||
		isSMBCommand(command) ||
		command == "backup schedule status" || command == "backup schedule off" || strings.HasPrefix(command, "backup schedule set ") ||
		strings.HasPrefix(command, "export start ") || command == "export cancel" || command == "export history" ||
		strings.HasPrefix(command, "tunnel ") || strings.HasPrefix(command, "frp ") ||
		strings.HasPrefix(command, "cinema tmdb ") || strings.HasPrefix(command, "map tianditu ") ||
		strings.HasPrefix(command, "trash ") || strings.HasPrefix(command, "notify ")
}

func queueDefaultMediaRefresh(registry *roots.Registry, rootServer *server.RootServer, dirs []string) {
	if root, ok := registry.Default(); ok {
		rootServer.QueueNativeRootRefreshDirs(root.ID, root.Generation, dirs)
	}
}

func handleAdminShareRemoteIPC(
	ctx context.Context,
	command string,
	accountStore *auth.Store,
	rootRegistry *roots.Registry,
	rootServer *server.RootServer,
	monitor *system.Collector,
	remote *atomic.Pointer[server.Remote],
	handler http.Handler,
	dataDir string,
	port int,
) bool {
	if command == "share status" {
		// A read-only physical identity check, not a reconnect. The
		// native menu-bar app uses it to detect a disk unplugged while
		// nobody has an HTTP file-management page open.
		path, online := registeredDefaultState(rootRegistry)
		if online {
			writeStdoutLine("LIGHTISLE_SHARE_STATUS 1")
		} else {
			writeStdoutLine("LIGHTISLE_SHARE_STATUS 0")
			writeStdoutLine("LIGHTISLE_SHARE_OFFLINE_PATH " + base64.RawURLEncoding.EncodeToString([]byte(path)))
		}
		return true
	}
	if strings.HasPrefix(command, "admin reset ") {
		// Only the parent Mac UI writes this pipe after owner
		// authentication. This parser does not grant authorization.
		password, valid := parseNativeAdminPassword(strings.TrimPrefix(command, "admin reset "))
		if !valid {
			writeStdoutLine("LIGHTISLE_ADMIN_RESET_ERROR invalid_request")
			return true
		}
		username, err := accountStore.ResetFirstAdminPassword(password)
		switch {
		case err == nil:
			writeStdoutLine("LIGHTISLE_ADMIN_RESET_OK " + base64.RawURLEncoding.EncodeToString([]byte(username)))
		case errors.Is(err, auth.ErrInput):
			writeStdoutLine("LIGHTISLE_ADMIN_RESET_ERROR invalid_password")
		case errors.Is(err, auth.ErrNotFound):
			writeStdoutLine("LIGHTISLE_ADMIN_RESET_ERROR admin_missing")
		default:
			slog.Error("native administrator password reset failed", "error", err)
			writeStdoutLine("LIGHTISLE_ADMIN_RESET_ERROR internal_error")
		}
		return true
	}
	if strings.HasPrefix(command, "admin verify ") {
		credentials, valid := parseNativeAdminCredentials(strings.TrimPrefix(command, "admin verify "))
		if !valid {
			writeStdoutLine("LIGHTISLE_ADMIN_VERIFY_FAILED")
			return true
		}
		if accountStore.VerifyAdministrator(credentials.Username, credentials.Password) {
			writeStdoutLine("LIGHTISLE_ADMIN_VERIFIED")
			return true
		}
		writeStdoutLine("LIGHTISLE_ADMIN_VERIFY_FAILED")
		return true
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
			writeStdoutLine("LIGHTISLE_STATS_ERROR")
			return true
		}
		payload, err := json.Marshal(reading)
		if err == nil {
			writeStdoutLine("LIGHTISLE_STATS " + base64.RawURLEncoding.EncodeToString(payload))
		}
		return true
	}
	if strings.HasPrefix(command, "admin init ") {
		credentials, valid := parseNativeAdminCredentials(strings.TrimPrefix(command, "admin init "))
		if !valid {
			writeStdoutLine("LIGHTISLE_INIT_ERROR invalid_request")
			return true
		}
		err := accountStore.Setup(credentials.Username, credentials.Password)
		switch {
		case err == nil:
			writeStdoutLine("LIGHTISLE_INITIALIZED")
			writeStdoutLine("LIGHTISLE_ADMIN_ACCOUNT " + base64.RawURLEncoding.EncodeToString([]byte(credentials.Username)))
		case errors.Is(err, auth.ErrExists):
			writeStdoutLine("LIGHTISLE_INIT_ERROR already_configured")
		case errors.Is(err, auth.ErrInput):
			writeStdoutLine("LIGHTISLE_INIT_ERROR invalid_credentials")
		default:
			slog.Error("native initialization failed", "error", err)
			writeStdoutLine("LIGHTISLE_INIT_ERROR internal_error")
		}
		return true
	}
	// Retired path-only mutation commands are intentionally not able
	// to change the active NAS root or resurrect abandoned metadata.
	if strings.HasPrefix(command, "share set ") || strings.HasPrefix(command, "share forget ") {
		writeStdoutLine("LIGHTISLE_SHARE_ERROR root_registry_only")
		return true
	}
	if command == "share retry" {
		selected, configured := rootRegistry.Default()
		if !configured {
			writeStdoutLine("LIGHTISLE_SHARE_ERROR default_root_not_configured")
			return true
		}
		if _, online := registeredDefaultState(rootRegistry); !online {
			rebound, err := rootRegistry.Rebind(ctx, selected.ID, selected.Path)
			if err != nil {
				writeStdoutLine("LIGHTISLE_SHARE_ERROR " + sanitizeIPCText(err.Error()))
				return true
			}
			if accountStore != nil {
				_ = accountStore.SyncVerifiedRootGeneration(rebound.ID, rebound.Generation)
			}
		} else if accountStore != nil {
			_ = accountStore.SyncVerifiedRootGeneration(selected.ID, selected.Generation)
		}
		queueDefaultMediaRefresh(rootRegistry, rootServer, []string{"."})
		writeStdoutLine("LIGHTISLE_SHARE_ON " + sanitizeIPCText(filepath.Base(selected.Path)))
		writeStdoutLine("LIGHTISLE_SHARE_PATH " + base64.RawURLEncoding.EncodeToString([]byte(selected.Path)))
		return true
	}
	if command == "remote off" || command == "remote on" || command == "remote http on" {
		if command == "remote off" {
			if prev := remote.Swap(nil); prev != nil {
				prev.Stop()
			}
			writeStdoutLine("LIGHTISLE_REMOTE_OFF")
		} else {
			cur := remote.Load()
			if cur == nil || (command == "remote http on") != strings.HasPrefix(cur.URL, "http://") {
				if prev := remote.Swap(nil); prev != nil {
					prev.Stop()
					writeStdoutLine("LIGHTISLE_REMOTE_OFF")
				}
				var next *server.Remote
				var err error
				if command == "remote http on" {
					next, err = server.NewRemoteHTTP(handler, accountStore, port)
				} else {
					next, err = server.NewRemote(handler, accountStore, dataDir, port)
				}
				if err != nil {
					slog.Warn("remote activation refused", "error", err)
					writeStdoutLine("LIGHTISLE_REMOTE_ERROR " + sanitizeIPCText(err.Error()))
					return true
				}
				remote.Store(next)
				fingerprint := next.Fingerprint
				if fingerprint == "" {
					fingerprint = "-"
				}
				writeStdoutLine(fmt.Sprintf("LIGHTISLE_REMOTE_ON %s %s", next.URL, fingerprint))
			}
		}
		return true
	}
	return false
}

func emitInitialReadyState(listenerAddr string, accountStore *auth.Store, rootRegistry *roots.Registry) {
	writeStdoutLine(fmt.Sprintf("LIGHTISLE_READY http://%s", listenerAddr))
	configured, configurationError := accountStore.Configured()
	if configurationError == nil {
		if configured {
			writeStdoutLine("LIGHTISLE_CONFIGURED 1")
		} else {
			writeStdoutLine("LIGHTISLE_CONFIGURED 0")
		}
	}
	selectedRoot, shareOnline := registeredDefaultState(rootRegistry)
	if selectedRoot == "" {
		writeStdoutLine("LIGHTISLE_SHARE_ON unconfigured")
	} else {
		writeStdoutLine("LIGHTISLE_SHARE_ON " + sanitizeIPCText(filepath.Base(selectedRoot)))
	}
	if configured {
		if username, err := accountStore.FirstAdminUsername(); err == nil {
			writeStdoutLine("LIGHTISLE_ADMIN_ACCOUNT " + base64.RawURLEncoding.EncodeToString([]byte(username)))
		}
	}
	if shareOnline {
		writeStdoutLine("LIGHTISLE_SHARE_PATH " + base64.RawURLEncoding.EncodeToString([]byte(selectedRoot)))
	}
	if !shareOnline {
		writeStdoutLine("LIGHTISLE_SHARE_ERROR 共享卷当前未挂载，请在设置中重新连接")
		writeStdoutLine("LIGHTISLE_SHARE_OFFLINE_PATH " + base64.RawURLEncoding.EncodeToString([]byte(selectedRoot)))
	}
}
