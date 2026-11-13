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
func synthesizeTrashEntry(t *testing.T, trashDir, id string, deletedAt time.Time) {
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
}

func managerTrashDir(dataDir string) string {
	return filepath.Join(dataDir, "SharedFiles", Trash)
}

// An oversized trash directory must not lock the list endpoint behind a
// trash_too_large error.
func TestTrashListCapsResponseOnOversizedTrash(t *testing.T) {
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
		synthesizeTrashEntry(t, trashDir, fmt.Sprintf("%032x", i), stale)
	}

	entries, err := m.TrashList()
	if err != nil {
		t.Fatalf("oversized trash must not error the list endpoint: %v", err)
	}
	if len(entries) != maxTrashListEntries {
		t.Fatalf("TrashList returned %d entries, want the %d cap", len(entries), maxTrashListEntries)
	}
}
