package files

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestUnknownUploadEntriesArePagedWithoutFollowingOrDeleting(t *testing.T) {
	m, root := newScanManager(t, 0)
	if _, err := m.BeginUpload("real.txt", 4, 1); err != nil {
		t.Fatal(err)
	}
	staging := filepath.Join(root, uploadsDir)
	for _, name := range []string{"z-unknown", "a-unknown", "b-unknown"} {
		if err := os.WriteFile(filepath.Join(staging, name), []byte(name), 0600); err != nil {
			t.Fatal(err)
		}
	}
	outside := filepath.Join(t.TempDir(), "keep")
	if err := os.WriteFile(outside, []byte("preserved"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(staging, "c-link")); err != nil {
		t.Fatal(err)
	}
	first, next, err := m.ListUnknownUploadEntries(context.Background(), "", 2)
	if err != nil || !reflect.DeepEqual(first, []string{"a-unknown", "b-unknown"}) || next != "b-unknown" {
		t.Fatalf("first page=%q next=%q err=%v", first, next, err)
	}
	second, next, err := m.ListUnknownUploadEntries(context.Background(), next, 2)
	if err != nil || !reflect.DeepEqual(second, []string{"c-link", "z-unknown"}) || next != "" {
		t.Fatalf("second page=%q next=%q err=%v", second, next, err)
	}
	if data, err := os.ReadFile(outside); err != nil || string(data) != "preserved" {
		t.Fatalf("external data changed: %q %v", data, err)
	}
	m.uploadMu.Lock()
	_, _, err = m.ListUnknownUploadEntries(context.Background(), "", 2)
	m.uploadMu.Unlock()
	if err != nil {
		t.Fatalf("read-only inventory blocked an active upload: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := m.ListUnknownUploadEntries(ctx, "", 2); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation ignored: %v", err)
	}
}
