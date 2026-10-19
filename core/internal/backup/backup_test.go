package backup

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func await(t *testing.T, s *Service) Status {
	t.Helper()
	until := time.Now().Add(8 * time.Second)
	for time.Now().Before(until) {
		st := s.Status()
		if !st.Running {
			return st
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("backup timed out: %+v", s.Status())
	return Status{}
}
func TestLargeCopyCancellation(t *testing.T) {
	folder := t.TempDir()
	src, err := os.Create(filepath.Join(folder, "src"))
	if err != nil {
		t.Fatal(err)
	}
	defer src.Close()
	if _, err := src.Write(bytes.Repeat([]byte{31}, 512<<10)); err != nil {
		t.Fatal(err)
	}
	if _, err := src.Seek(0, 0); err != nil {
		t.Fatal(err)
	}
	dst, err := os.Create(filepath.Join(folder, "dst"))
	if err != nil {
		t.Fatal(err)
	}
	defer dst.Close()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := boundedCopy(ctx, dst, src, 512<<10); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled copy continued: %v", err)
	}
}
func TestBackupRestoreChecksumsAndNoOverwrite(t *testing.T) {
	base := t.TempDir()
	share, err := files.NewManager(base)
	if err != nil {
		t.Fatal(err)
	}
	defer share.Close()
	dir := filepath.Join(base, "SharedFiles")
	if err := os.Mkdir(filepath.Join(dir, "Camera"), 0700); err != nil {
		t.Fatal(err)
	}
	first := filepath.Join(dir, "Camera", "picture.jpg")
	if err := os.WriteFile(first, []byte("original image bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/etc/passwd", filepath.Join(dir, "outside.txt")); err != nil {
		t.Fatal(err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	destination, err := os.MkdirTemp(home, "lightisle-m5-backup-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(destination)
	svc := New(share)
	defer svc.Close()
	if err := svc.StartBackup(dir); err != nil {
		t.Fatal(err)
	}
	if status := await(t, svc); !strings.Contains(status.LastError, ErrInvalid.Error()) {
		t.Fatalf("allowed in-place backup: %+v", status)
	}
	if err := svc.StartBackup(destination); err != nil {
		t.Fatal(err)
	}
	st := await(t, svc)
	if st.LastError != "" || st.Files != 1 || st.LastSnapshot == "" {
		t.Fatalf("backup status: %+v", st)
	}
	data, err := os.ReadFile(filepath.Join(st.LastSnapshot, "data", "Camera", "picture.jpg"))
	if err != nil || !bytes.Equal(data, []byte("original image bytes")) {
		t.Fatalf("backup contents: %q %v", data, err)
	}
	if _, err := os.Stat(filepath.Join(st.LastSnapshot, "data", "outside.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("symlink leak: %v", err)
	}
	if err := os.WriteFile(first, []byte("newer user image"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := svc.StartRestore(st.LastSnapshot); err != nil {
		t.Fatal(err)
	}
	restored := await(t, svc)
	if restored.LastError != "" || restored.LastSnapshot == "" {
		t.Fatalf("restore status: %+v", restored)
	}
	result, err := os.ReadFile(filepath.Join(restored.LastSnapshot, "Camera", "picture.jpg"))
	if err != nil || !bytes.Equal(result, []byte("original image bytes")) {
		t.Fatalf("restore mismatch: %q %v", result, err)
	}
	current, err := os.ReadFile(first)
	if err != nil || string(current) != "newer user image" {
		t.Fatalf("overwrite existing file: %q %v", current, err)
	}
	snapshot := st.LastSnapshot
	if err := os.WriteFile(filepath.Join(snapshot, "data", "Camera", "picture.jpg"), []byte("tampered file data!!"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := svc.StartRestore(snapshot); err != nil {
		t.Fatal(err)
	}
	damaged := await(t, svc)
	if !strings.Contains(damaged.LastError, "backup_checksum_mismatch") {
		t.Fatalf("corruption not detected: %+v", damaged)
	}
	if strings.Contains(damaged.LastSnapshot, ".partial") {
		t.Fatalf("recovery staging surfaced: %+v", damaged)
	}
}
func TestManifestRejectsTraversalAndOverlap(t *testing.T) {
	dir := t.TempDir()
	share, err := files.NewManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer share.Close()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	destination, err := os.MkdirTemp(home, "lightisle-m5-invalid-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(destination)
	if _, err := authorizedFolder("/"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("system folder accepted: %v", err)
	}
	if !safeName("Photos/1.png") || safeName("../secrets") || safeName("/etc/passwd") || safeName("Photos/.lightisle-parts/data") {
		t.Fatal("unsafe backup paths accepted")
	}
	if err := disjoint(dir, filepath.Join(dir, "SharedFiles")); !errors.Is(err, ErrInvalid) {
		t.Fatalf("overlap accepted %v", err)
	}
	if err := os.WriteFile(filepath.Join(destination, "manifest.json"), []byte(`{"format":"lightisle-file-backup-v1","files":[{"path":"../secret","size":10,"sha256":"0123456789012345678901234567890123456789012345678901234567890123"}]}`), 0600); err != nil {
		t.Fatal(err)
	}
	s := New(share)
	defer s.Close()
	if err := s.StartRestore(destination); err != nil {
		t.Fatal(err)
	}
	if st := await(t, s); !strings.Contains(st.LastError, ErrInvalid.Error()) {
		t.Fatalf("traversal in manifest accepted: %+v", st)
	}
}
