package files

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// synthesizeTrashEntry writes a journal + content directory directly, the
// same on-disk shape MoveToTrash leaves behind, without paying a real move
// and fsync per item. It exists so tests can build oversized trash states
// quickly.
func synthesizeTrashEntry(t *testing.T, trashDir, id string, deletedAt time.Time, stuckInner bool) string {
	t.Helper()
	entry := TrashEntry{
		ID:           id,
		OriginalPath: "old/file-" + id,
		Name:         "file-" + id,
		DeletedAt:    deletedAt.UTC(),
	}
	data, err := json.Marshal(entry)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(trashDir, id+".json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	content := filepath.Join(trashDir, id)
	if err := os.Mkdir(content, 0o700); err != nil {
		t.Fatal(err)
	}
	if stuckInner {
		inner := filepath.Join(content, "inner")
		if err := os.Mkdir(inner, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(inner, "x.txt"), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(inner, 0o500); err != nil {
			t.Fatal(err)
		}
	}
	return content
}

func managerTrashDir(dataDir string) string {
	return filepath.Join(dataDir, "SharedFiles", Trash)
}

// An oversized trash directory must not lock the list endpoint behind a
// trash_too_large error nor stop the sweeper from draining it.
func TestTrashListCapsResponseAndSweeperDrainsOversizedTrash(t *testing.T) {
	dataDir := t.TempDir()
	m, err := NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	trashDir := managerTrashDir(dataDir)
	if err := os.MkdirAll(trashDir, 0o700); err != nil {
		t.Fatal(err)
	}
	const total = maxTrashListEntries + 50
	stale := time.Now().Add(-48 * time.Hour)
	for i := 0; i < total; i++ {
		synthesizeTrashEntry(t, trashDir, fmt.Sprintf("%032x", i), stale, false)
	}

	entries, err := m.TrashList()
	if err != nil {
		t.Fatalf("oversized trash must not error the list endpoint: %v", err)
	}
	if len(entries) != maxTrashListEntries {
		t.Fatalf("TrashList returned %d entries, want the %d cap", len(entries), maxTrashListEntries)
	}

	cutoff := time.Now().Add(-24 * time.Hour)
	purgedTotal := 0
	rounds := 0
	for {
		purged, failed, _, err := m.SweepTrashExpired(cutoff, 100)
		if err != nil {
			t.Fatalf("sweep round: %v", err)
		}
		if len(failed) != 0 {
			t.Fatalf("unexpected failed purges: %v", failed)
		}
		rounds++
		purgedTotal += len(purged)
		if len(purged) == 0 {
			break
		}
	}
	if purgedTotal != total {
		t.Fatalf("drained %d items, want %d over %d rounds", purgedTotal, total, rounds)
	}
	if left, err := m.TrashList(); err != nil || len(left) != 0 {
		t.Fatalf("trash not empty after draining: %d left, err %v", len(left), err)
	}
}

// Items that keep failing to purge are reported back instead of being
// swallowed, so the sweeper can keep its cleanup alert raised.
func TestSweepReportsStuckItemsInsteadOfSwallowing(t *testing.T) {
	dataDir := t.TempDir()
	m, err := NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	trashDir := managerTrashDir(dataDir)
	if err := os.MkdirAll(trashDir, 0o700); err != nil {
		t.Fatal(err)
	}
	stale := time.Now().Add(-48 * time.Hour)
	okID := fmt.Sprintf("%032x", 1)
	stuckID := fmt.Sprintf("%032x", 2)
	synthesizeTrashEntry(t, trashDir, okID, stale, false)
	stuckContent := synthesizeTrashEntry(t, trashDir, stuckID, stale, true)
	// Restore permissions so t.TempDir cleanup can delete the tree.
	t.Cleanup(func() { _ = os.Chmod(filepath.Join(stuckContent, "inner"), 0o700) })

	purged, failed, scanned, err := m.SweepTrashExpired(time.Now().Add(-24*time.Hour), 10)
	if err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if len(purged) != 1 || purged[0] != okID {
		t.Fatalf("purged = %v, want [%s]", purged, okID)
	}
	if len(failed) != 1 || failed[0] != stuckID {
		t.Fatalf("failed = %v, want [%s]", failed, stuckID)
	}
	if scanned != 2 {
		t.Fatalf("scanned = %d, want 2", scanned)
	}
	// The stuck item is still in the trash and still listed.
	left, err := m.TrashList()
	if err != nil || len(left) != 1 || left[0].ID != stuckID {
		t.Fatalf("stuck item must remain listed: %+v err %v", left, err)
	}
}
