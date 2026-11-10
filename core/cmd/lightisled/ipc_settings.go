//go:build darwin && arm64

package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/maptiles"
	"github.com/lengsukq/lightisle/core/internal/server"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

// Only the native owner's private IPC channel may invoke these handlers.
// Malformed subcommands are consumed and never fall through to other routes.
func handleMapSettings(command string) bool {
	if !strings.HasPrefix(command, "map tianditu ") {
		return false
	}
	switch {
	case strings.HasPrefix(command, "map tianditu set "):
		raw, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(strings.TrimPrefix(command, "map tianditu set ")))
		if err != nil || maptiles.Default.Set(string(raw)) != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_MAP_ERROR invalid_map_key")
			return true
		}
	case command == "map tianditu clear":
		maptiles.Default.Clear()
	case command != "map tianditu status":
		fmt.Fprintln(os.Stdout, "LIGHTISLE_MAP_ERROR invalid_map_command")
		return true
	}
	if payload, err := json.Marshal(map[string]bool{"configured": maptiles.Default.Configured()}); err == nil {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_MAP_STATE "+base64.RawURLEncoding.EncodeToString(payload))
	}
	return true
}

// Native TMDB configuration is global to the owner, while each registered
// physical root keeps its own cinema database and scan lifecycle.
func handleRootCinemaTokenSettings(command string, rootsServer *server.RootServer) bool {
	if !strings.HasPrefix(command, "cinema tmdb ") {
		return false
	}
	if rootsServer == nil {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_TMDB_ERROR root_services_unavailable")
		return true
	}
	switch {
	case strings.HasPrefix(command, "cinema tmdb set "):
		raw, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(strings.TrimPrefix(command, "cinema tmdb set ")))
		if err != nil || rootsServer.SetTMDBToken(string(raw)) != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_TMDB_ERROR invalid_tmdb_token")
			return true
		}
	case command == "cinema tmdb clear":
		rootsServer.ClearTMDBToken()
	case command != "cinema tmdb status":
		fmt.Fprintln(os.Stdout, "LIGHTISLE_TMDB_ERROR invalid_tmdb_command")
		return true
	}
	if payload, err := json.Marshal(map[string]bool{"configured": rootsServer.TMDBTokenConfigured()}); err == nil {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_TMDB_STATE "+base64.RawURLEncoding.EncodeToString(payload))
	}
	return true
}

// Alerts are a private native IPC capability; the HTTP side only presents the
// normalized status according to its own authorization checks.
func handleAlertSettings(command string, journal *tasks.Journal, thresholds *tasks.ThresholdStore) bool {
	if command == "alerts status" {
		if journal == nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_ALERTS_ERROR")
			return true
		}
		alerts, err := journal.Alerts(true)
		if err != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_ALERTS_ERROR")
		} else if payload, err := json.Marshal(alerts); err == nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_ALERTS "+base64.RawURLEncoding.EncodeToString(payload))
		}
		return true
	}
	if command != "alerts threshold" && !strings.HasPrefix(command, "alerts threshold ") {
		return false
	}
	if encoded := strings.TrimPrefix(command, "alerts threshold"); strings.TrimSpace(encoded) != "" {
		raw, decodeErr := base64.RawURLEncoding.DecodeString(strings.TrimSpace(encoded))
		var request tasks.Threshold
		if decodeErr != nil || len(raw) == 0 || len(raw) > 256 || json.Unmarshal(raw, &request) != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_ALERTS_THRESHOLD_ERROR invalid_storage_threshold")
			return true
		}
		if _, err := thresholds.Set(request); err != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_ALERTS_THRESHOLD_ERROR "+err.Error())
			return true
		}
	}
	if payload, err := json.Marshal(thresholds.Get()); err == nil {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_ALERTS_THRESHOLD "+base64.RawURLEncoding.EncodeToString(payload))
	}
	return true
}

func handleCinemaTokenSettings(command string, library *cinema.Library) bool {
	if !strings.HasPrefix(command, "cinema tmdb ") {
		return false
	}
	switch {
	case strings.HasPrefix(command, "cinema tmdb set "):
		raw, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(strings.TrimPrefix(command, "cinema tmdb set ")))
		if err != nil || library.SetTMDBToken(string(raw)) != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_TMDB_ERROR invalid_tmdb_token")
			return true
		}
	case command == "cinema tmdb clear":
		library.ClearTMDBToken()
	}
	if payload, err := json.Marshal(map[string]bool{"configured": library.TMDBTokenConfigured()}); err == nil {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_TMDB_STATE "+base64.RawURLEncoding.EncodeToString(payload))
	}
	return true
}

func handleTrashRetentionSettings(command string, retention *tasks.RetentionStore) bool {
	if !strings.HasPrefix(command, "trash retention") {
		return false
	}
	if encoded := strings.TrimPrefix(command, "trash retention"); strings.TrimSpace(encoded) != "" {
		raw, decodeErr := base64.RawURLEncoding.DecodeString(strings.TrimSpace(encoded))
		var request tasks.Retention
		if decodeErr != nil || len(raw) == 0 || len(raw) > 256 || json.Unmarshal(raw, &request) != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_TRASH_RETENTION_ERROR invalid_trash_retention")
			return true
		}
		if !request.Enabled && request.Days != 0 {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_TRASH_RETENTION_ERROR invalid_trash_retention")
			return true
		}
		if request.Enabled && (request.Days < tasks.MinRetentionDays || request.Days > tasks.MaxRetentionDays) {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_TRASH_RETENTION_ERROR invalid_trash_retention")
			return true
		}
		if _, err := retention.Set(request); err != nil {
			fmt.Fprintln(os.Stdout, "LIGHTISLE_TRASH_RETENTION_ERROR "+err.Error())
			return true
		}
	}
	if payload, err := json.Marshal(retention.Get()); err == nil {
		fmt.Fprintln(os.Stdout, "LIGHTISLE_TRASH_RETENTION "+base64.RawURLEncoding.EncodeToString(payload))
	}
	return true
}
