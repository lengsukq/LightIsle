package files

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestDirectoryCopyAtomicAndExclusive(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, name := range []string{"albums", "albums/2026", "destination"} {
		if err := s.Mkdir(name); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"albums/cover.jpg", "albums/2026/family.jpg"} {
		if _, err := s.Upload(name, bytes.NewReader([]byte("verified content"))); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.Copy("albums", "destination/backup"); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"destination/backup/cover.jpg", "destination/backup/2026/family.jpg"} {
		f, _, err := s.Read(name)
		if err != nil {
			t.Fatal(err)
		}
		raw := make([]byte, 16)
		_, err = f.Read(raw)
		f.Close()
		if err != nil {
			t.Fatal(err)
		}
		if string(raw) != "verified content" {
			t.Fatalf("copy checksum failure %q", raw)
		}
	}
	if err := s.Copy("albums", "destination/backup"); !errors.Is(err, ErrExists) {
		t.Fatalf("directory overwrite: %v", err)
	}
	if err := s.Move("albums", "destination/backup"); !errors.Is(err, ErrExists) {
		t.Fatalf("directory move overwrite: %v", err)
	}
	if err := s.Move("albums", "destination/renamed"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Read("destination/renamed/2026/family.jpg"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Read("albums/cover.jpg"); !os.IsNotExist(err) {
		t.Fatalf("source was not moved: %v", err)
	}
}

func TestDirectoryCopyCancelAndRejectSymlinksWithoutPartialDestination(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Mkdir("safe"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Upload("safe/item.txt", bytes.NewReader([]byte("original"))); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := s.CopyContext(ctx, "safe", "cancelled"); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled copy succeeded: %v", err)
	}
	if _, err := s.root.Lstat("cancelled"); !os.IsNotExist(err) {
		t.Fatalf("partial destination published: %v", err)
	}
	if err := os.Symlink("../safe/item.txt", filepath.Join(s.root.Name(), "safe", "linked.txt")); err != nil {
		t.Fatal(err)
	}
	if err := s.Copy("safe", "unsafe"); err == nil {
		t.Fatal("silently skipped source symlink")
	}
	if _, err := s.root.Lstat("unsafe"); !os.IsNotExist(err) {
		t.Fatalf("failed directory copy published: %v", err)
	}
	entries, err := s.List(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if entry.Name == "unsafe" || entry.Name == "cancelled" {
			t.Fatalf("partial copy visible: %+v", entry)
		}
	}
	if _, _, err := s.Read("safe/item.txt"); err != nil {
		t.Fatalf("source damaged: %v", err)
	}
}

func TestCopyRefusesChangedDestination(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.Upload("source", bytes.NewReader([]byte("correct"))); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Upload("target", bytes.NewReader([]byte("untouchable"))); err != nil {
		t.Fatal(err)
	}
	if err := s.Copy("source", "target"); !errors.Is(err, ErrExists) {
		t.Fatalf("file overwritten: %v", err)
	}
	f, _, err := s.Read("target")
	if err != nil {
		t.Fatal(err)
	}
	data := make([]byte, 11)
	_, err = f.Read(data)
	f.Close()
	if err != nil || string(data) != "untouchable" {
		t.Fatalf("target overwritten: %q %v", data, err)
	}
}
