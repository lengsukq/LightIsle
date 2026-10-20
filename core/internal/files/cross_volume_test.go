package files

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Deterministically emulate a process termination signal after the staging
// copy has started, without depending on nondeterministic wall-clock races.
type failDuringCopyContext struct {
	context.Context
	checks int
}

func TestCopyOutMidStreamFailureDoesNotPublishPartialFile(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	data := bytes.Repeat([]byte{97}, 4<<20)
	if _, err := s.Upload("large.bin", bytes.NewReader(data)); err != nil {
		t.Fatal(err)
	}
	dst := testExportRoot(t)
	ctx := &failDuringCopyContext{Context: context.Background()}
	if _, err := s.CopyOut(ctx, "large.bin", dst); !errors.Is(err, context.Canceled) {
		t.Fatalf("mid-stream cancellation returned %v", err)
	}
	if _, err := os.Stat(filepath.Join(dst, "large.bin")); !os.IsNotExist(err) {
		t.Fatalf("partially copied file published: %v", err)
	}
	entries, err := os.ReadDir(dst)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("aborted export residue: %+v", entries)
	}
	f, _, err := s.Read("large.bin")
	if err != nil {
		t.Fatal(err)
	}
	info, err := f.Stat()
	f.Close()
	if err != nil || info.Size() != int64(len(data)) {
		t.Fatalf("source was modified: %v %v", info, err)
	}
}
func (c *failDuringCopyContext) Err() error {
	c.checks++
	if c.checks >= 5 {
		return context.Canceled
	}
	return nil
}

func testExportRoot(t *testing.T) string {
	t.Helper()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	dir, err := os.MkdirTemp(home, "lightisle-cross-volume-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

func TestCopyOutFileAndDirectoryNoOverwrite(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, dir := range []string{"albums", "albums/2026"} {
		if err := s.Mkdir(dir); err != nil {
			t.Fatal(err)
		}
	}
	data := bytes.Repeat([]byte("LightIsle-export-verified"), 1000)
	for _, name := range []string{"albums/root.txt", "albums/2026/family.txt"} {
		if _, err := s.Upload(name, bytes.NewReader(data)); err != nil {
			t.Fatal(err)
		}
	}
	dst := testExportRoot(t)
	path, err := s.CopyOut(context.Background(), "albums", dst)
	if err != nil {
		t.Fatal(err)
	}
	if path != filepath.Join(dst, "albums") {
		t.Fatalf("bad export path %q", path)
	}
	for _, filename := range []string{"root.txt", "2026/family.txt"} {
		b, err := os.ReadFile(filepath.Join(path, filename))
		if err != nil || !bytes.Equal(b, data) {
			t.Fatalf("copy corrupted %q: %v", filename, err)
		}
	}
	if _, err := s.CopyOut(context.Background(), "albums", dst); !errors.Is(err, ErrExists) {
		t.Fatalf("overwrite directory allowed: %v", err)
	}
	path, err = s.CopyOut(context.Background(), "albums/2026/family.txt", dst)
	if err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(path); err != nil || !bytes.Equal(b, data) {
		t.Fatalf("single export corrupted: %v", err)
	}
	if _, err := s.CopyOut(context.Background(), "albums/2026/family.txt", dst); !errors.Is(err, ErrExists) {
		t.Fatalf("overwrite file allowed: %v", err)
	}
	for _, orig := range []string{"albums/root.txt", "albums/2026/family.txt"} {
		f, _, err := s.Read(orig)
		if err != nil {
			t.Fatalf("export removed source %q: %v", orig, err)
		}
		f.Close()
	}
}

func TestCopyOutCancelInvalidDestinationAndSymlinkNoDisclosure(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Mkdir("photos"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Upload("photos/a.txt", bytes.NewBufferString("trusted")); err != nil {
		t.Fatal(err)
	}
	dst := testExportRoot(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := s.CopyOut(ctx, "photos", dst); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation ignored: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dst, "photos")); !os.IsNotExist(err) {
		t.Fatalf("partial folder published: %v", err)
	}
	if err := os.Symlink("../photos/a.txt", filepath.Join(s.root.Name(), "photos", "alias")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CopyOut(context.Background(), "photos", dst); err == nil {
		t.Fatal("export copied symlinked entry")
	}
	if _, err := os.Stat(filepath.Join(dst, "photos")); !os.IsNotExist(err) {
		t.Fatalf("unsafe partial folder published: %v", err)
	}
	entries, err := os.ReadDir(dst)
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range entries {
		if strings.HasPrefix(item.Name(), ".lightisle-transfer-") {
			t.Fatalf("failed export left stage %q", item.Name())
		}
	}
	if _, err := s.CopyOut(context.Background(), "photos/a.txt", s.root.Name()); !errors.Is(err, ErrPath) {
		t.Fatalf("in-place export allowed: %v", err)
	}
	if _, err := s.CopyOut(context.Background(), "photos/a.txt", "/"); err == nil {
		t.Fatal("system directory accepted")
	}
}
