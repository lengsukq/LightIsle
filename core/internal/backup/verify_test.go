package backup

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestVerifySnapshotDetectsTamperingAndSymlinks(t *testing.T) {
	base := t.TempDir()
	manager, err := files.NewManager(base)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	if _, err := manager.Upload("picture.jpg", bytes.NewBufferString("original-photo")); err != nil {
		t.Fatal(err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	target, err := os.MkdirTemp(home, "lightisle-verify-snapshot-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(target)
	svc := New(manager)
	defer svc.Close()
	if err := svc.StartBackup(target); err != nil {
		t.Fatal(err)
	}
	status := await(t, svc)
	if status.LastError != "" {
		t.Fatal(status.LastError)
	}
	ctx := context.Background()
	report, err := VerifySnapshot(ctx, status.LastSnapshot)
	if err != nil || !report.Verified || report.Files != 1 {
		t.Fatalf("verified report %+v %v", report, err)
	}
	file := filepath.Join(status.LastSnapshot, "data", "picture.jpg")
	if err := os.WriteFile(file, []byte("tampered-photo"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := VerifySnapshot(ctx, status.LastSnapshot); err == nil {
		t.Fatal("content corruption passed integrity verification")
	}
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/etc/passwd", file); err != nil {
		t.Fatal(err)
	}
	if _, err := VerifySnapshot(ctx, status.LastSnapshot); err == nil {
		t.Fatal("symlinked snapshot passed integrity verification")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := VerifySnapshot(cancelled, status.LastSnapshot); err == nil {
		t.Fatal("cancelled verification passed")
	}
}
