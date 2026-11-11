//go:build darwin && arm64

package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/apps"
)

func TestReadIPCCommandLinesHandlesLargeAndOversizedLinesWithoutDying(t *testing.T) {
	// 100 KiB command (> legacy 16 KiB scanner limit, <= 256 KiB ceiling)
	largeCmd := "disks smart-update " + strings.Repeat("A", 100*1024)
	// 300 KiB command (> 256 KiB ceiling, must be drained & dropped with warning, NOT killing reader)
	oversizedCmd := "oversized " + strings.Repeat("B", 300*1024)

	stream := strings.Join([]string{
		"stats summary",
		largeCmd,
		oversizedCmd,
		"apps list",
		"shutdown",
		"after-shutdown-ignored",
	}, "\n") + "\n"

	var stderr bytes.Buffer
	var delivered []string
	readIPCCommandLines(strings.NewReader(stream), &stderr, func(cmd string) bool {
		delivered = append(delivered, cmd)
		return true
	})

	if len(delivered) != 3 {
		t.Fatalf("expected 3 delivered commands before shutdown, got %d", len(delivered))
	}
	if delivered[0] != "stats summary" {
		t.Fatalf("delivered[0] = %q", delivered[0])
	}
	if delivered[1] != largeCmd {
		t.Fatalf("expected 100 KiB command delivered intact (len=%d, want %d)", len(delivered[1]), len(largeCmd))
	}
	if delivered[2] != "apps list" {
		t.Fatalf("delivered[2] = %q, want %q", delivered[2], "apps list")
	}
	if !strings.Contains(stderr.String(), "dropped oversized IPC line") {
		t.Fatalf("expected stderr warning for >256 KiB line, got %q", stderr.String())
	}
}

func TestExportAppDataAtomicallyPreservesExistingTargetOnError(t *testing.T) {
	dataDir := t.TempDir()
	appsMgr := apps.NewManager(dataDir, "lightisled", nil)
	defer appsMgr.Close()
	if err := appsMgr.Reload(); err != nil {
		t.Fatal(err)
	}

	exportDir := t.TempDir()
	targetPath := filepath.Join(exportDir, "existing-backup.tar.gz")
	preciousBytes := []byte("PRE-EXISTING-USER-ARCHIVE-DO-NOT-TRUNCATE-OR-DELETE")
	if err := os.WriteFile(targetPath, preciousBytes, 0600); err != nil {
		t.Fatal(err)
	}

	// Exporting a non-existent app fails inside ExportAppData after temp file creation.
	if _, err := exportAppDataAtomically(context.Background(), appsMgr, "non-existent-app", targetPath); err == nil {
		t.Fatalf("expected exportAppDataAtomically to fail for non-existent app")
	}

	afterBytes, err := os.ReadFile(targetPath)
	if err != nil {
		t.Fatalf("expected pre-existing target file to remain intact, ReadFile failed: %v", err)
	}
	if !bytes.Equal(afterBytes, preciousBytes) {
		t.Fatalf("pre-existing target file modified: got %q, want %q", string(afterBytes), string(preciousBytes))
	}

	entries, err := os.ReadDir(exportDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, ent := range entries {
		if strings.HasPrefix(ent.Name(), ".lightisle-app-backup-") {
			t.Fatalf("leftover temp backup file not cleaned up: %s", ent.Name())
		}
	}
}
