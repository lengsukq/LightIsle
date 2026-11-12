//go:build darwin && arm64

package main

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/roots"
)

const retiredRootsDirName = "retired-roots"

func isHexRootID(id string) bool {
	if len(id) != 32 {
		return false
	}
	for _, r := range id {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f')) {
			return false
		}
	}
	return true
}

// retireRemovedRootSQLite moves per-root derived SQLite indexes (gallery,
// cinema, tasks, plus -wal/-shm sidecars) and thumbnail caches for a removed
// root ID out of top-level dataDir into dataDir/retired-roots/. Source files on
// the physical NAS disk are never touched, and archiving keeps top-level SQLite
// inventory bounded well below NativeUpgradePreflight's 64-file safety cap.
func retireRemovedRootSQLite(dataDir, rootID string) {
	if dataDir == "" || !isHexRootID(rootID) {
		return
	}
	entries, err := os.ReadDir(dataDir)
	if err != nil {
		return
	}
	prefixes := []string{
		"gallery-root-" + rootID + ".sqlite",
		"cinema-root-" + rootID + ".sqlite",
		"tasks-root-" + rootID + ".sqlite",
		"thumbnails-root-" + rootID + "-",
	}
	var matched []string
	for _, entry := range entries {
		name := entry.Name()
		for _, pfx := range prefixes {
			if name == pfx || strings.HasPrefix(name, pfx) {
				matched = append(matched, name)
				break
			}
		}
	}
	if len(matched) == 0 {
		return
	}
	destDir := filepath.Join(dataDir, retiredRootsDirName, fmt.Sprintf("%s-%d", rootID, time.Now().Unix()))
	if err := os.MkdirAll(destDir, 0700); err != nil {
		slog.Warn("cannot create retired-roots directory", "error", err)
		return
	}
	for _, name := range matched {
		src := filepath.Join(dataDir, name)
		dst := filepath.Join(destDir, name)
		if err := os.Rename(src, dst); err != nil {
			slog.Warn("failed to archive retired root index", "file", name, "error", err)
		}
	}
}

// retireUnreferencedRootSQLiteOnStartup sweeps orphaned per-root SQLite files
// left behind by historical root removals before RootServer opens any runtime.
func retireUnreferencedRootSQLiteOnStartup(dataDir string, active []roots.Root) {
	if dataDir == "" {
		return
	}
	activeSet := make(map[string]bool, len(active))
	for _, r := range active {
		activeSet[r.ID] = true
	}
	entries, err := os.ReadDir(dataDir)
	if err != nil {
		return
	}
	orphaned := make(map[string]bool)
	for _, entry := range entries {
		name := entry.Name()
		for _, kind := range []string{"gallery-root-", "cinema-root-", "tasks-root-"} {
			if strings.HasPrefix(name, kind) && strings.HasSuffix(name, ".sqlite") {
				id := strings.TrimSuffix(strings.TrimPrefix(name, kind), ".sqlite")
				if isHexRootID(id) && !activeSet[id] {
					orphaned[id] = true
				}
			}
		}
	}
	for id := range orphaned {
		retireRemovedRootSQLite(dataDir, id)
	}
}
