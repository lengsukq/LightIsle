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
	"os"
	"path/filepath"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
	"github.com/lengsukq/lightisle/core/internal/system"
)

func isAcceptedIPCCommand(command string) bool {
	return strings.HasPrefix(command, "roots ") ||
		command == "spaces" || strings.HasPrefix(command, "spaces ") ||
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
	remote **server.Remote,
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
			fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_STATUS 1")
		} else {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_STATUS 0")
			fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_OFFLINE_PATH "+base64.RawURLEncoding.EncodeToString([]byte(path)))
		}
		return true
	}
	if strings.HasPrefix(command, "admin reset ") {
		// Only the parent Mac UI writes this pipe after owner
		// authentication. This parser does not grant authorization.
		password, valid := parseNativeAdminPassword(strings.TrimPrefix(command, "admin reset "))
		if !valid {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_RESET_ERROR invalid_request")
			return true
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
		return true
	}
	if strings.HasPrefix(command, "admin verify ") {
		credentials, valid := parseNativeAdminCredentials(strings.TrimPrefix(command, "admin verify "))
		if !valid {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_VERIFY_FAILED")
			return true
		}
		if accountStore.VerifyAdministrator(credentials.Username, credentials.Password) {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_VERIFIED")
			return true
		}
		fmt.Fprintln(os.Stdout, "LIGHTISLE_ADMIN_VERIFY_FAILED")
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
			fmt.Fprintln(os.Stdout, "LIGHTISLE_STATS_ERROR")
			return true
		}
		payload, err := json.Marshal(reading)
		if err == nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_STATS "+base64.RawURLEncoding.EncodeToString(payload))
		}
		return true
	}
	if strings.HasPrefix(command, "admin init ") {
		credentials, valid := parseNativeAdminCredentials(strings.TrimPrefix(command, "admin init "))
		if !valid {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_INIT_ERROR invalid_request")
			return true
		}
		err := accountStore.Setup(credentials.Username, credentials.Password)
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
		return true
	}
	// Retired path-only mutation commands are intentionally not able
	// to change the active NAS root or resurrect abandoned metadata.
	if strings.HasPrefix(command, "share set ") || strings.HasPrefix(command, "share forget ") {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ERROR root_registry_only")
		return true
	}
	if command == "share retry" {
		selected, configured := rootRegistry.Default()
		if !configured {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ERROR default_root_not_configured")
			return true
		}
		if _, online := registeredDefaultState(rootRegistry); !online {
			if _, err := rootRegistry.Rebind(ctx, selected.ID, selected.Path); err != nil {
				fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ERROR "+err.Error())
				return true
			}
		}
		queueDefaultMediaRefresh(rootRegistry, rootServer, []string{"."})
		fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_ON "+filepath.Base(selected.Path))
		fmt.Fprintln(os.Stdout, "LIGHTISLE_SHARE_PATH "+base64.RawURLEncoding.EncodeToString([]byte(selected.Path)))
		return true
	}
	if command == "remote off" || command == "remote on" || command == "remote http on" {
		if command == "remote off" {
			if *remote != nil {
				(*remote).Stop()
				*remote = nil
			}
			fmt.Fprintln(os.Stdout, "LIGHTISLE_REMOTE_OFF")
		} else if *remote == nil || (command == "remote http on") != strings.HasPrefix((*remote).URL, "http://") {
			if *remote != nil {
				(*remote).Stop()
				*remote = nil
				fmt.Fprintln(os.Stdout, "LIGHTISLE_REMOTE_OFF")
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
				fmt.Fprintln(os.Stdout, "LIGHTISLE_REMOTE_ERROR "+err.Error())
				return true
			}
			*remote = next
			fingerprint := (*remote).Fingerprint
			if fingerprint == "" {
				fingerprint = "-"
			}
			fmt.Fprintf(os.Stdout, "LIGHTISLE_REMOTE_ON %s %s\n", (*remote).URL, fingerprint)
		}
		return true
	}
	return false
}

func emitInitialReadyState(listenerAddr string, accountStore *auth.Store, rootRegistry *roots.Registry) {
	fmt.Fprintf(os.Stdout, "LIGHTISLE_READY http://%s\n", listenerAddr)
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
}
