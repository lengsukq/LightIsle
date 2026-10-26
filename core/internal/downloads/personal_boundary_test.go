package downloads

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestLegacyDownloadRejectsPersonalDestinationIncludingStagedNestedPaths(t *testing.T) {
	dir := t.TempDir()
	store, err := files.Open(filepath.Join(dir, "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	manager, err := New(Options{
		DataDir: dir, Publisher: newTestDownloadPublisher(store),
		CanImport: func(int64, string) bool { return true },
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	if _, err := manager.Create(2, "https://example.org/file", "Users/u2/files", 100); !errors.Is(err, ErrAccountingPending) {
		t.Fatalf("accepted unmetered personal download: %v", err)
	}
	if _, err := manager.Create(2, "https://example.org/file", "users/u2/files", 100); !errors.Is(err, ErrAccountingPending) {
		t.Fatalf("accepted case-insensitive private download destination: %v", err)
	}
	stage := manager.stagingDir("untrusted-staged")
	if err := os.MkdirAll(filepath.Join(stage, "Users", "u2", "files"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, "Users", "u2", "files", "bad.txt"), []byte("unsafe"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := manager.publishStaged(Task{ID: "untrusted-staged", Destination: ".", Owner: 2}); !errors.Is(err, ErrAccountingPending) {
		t.Fatalf("nested staged path bypassed account guard: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "share", "Users", "u2", "files", "bad.txt")); !os.IsNotExist(err) {
		t.Fatalf("unaccounted download reached destination: %v", err)
	}
}
