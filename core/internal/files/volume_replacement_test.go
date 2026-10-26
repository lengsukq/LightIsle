package files

import (
	"bytes"
	"errors"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
	"os"
	"path/filepath"
	"testing"
)

// Simulate a removable volume being unplugged and another disk appearing at
// the same mountpoint. Never silently write into that different filesystem.
func TestVolumePathReplacementRequiresOwnerReselectionAcrossRestart(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	dataDir, err := os.MkdirTemp(home, ".lightisle-volume-identity-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dataDir)
	m, err := NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	original, online := m.State()
	if !online {
		t.Fatal("initial default share offline")
	}
	if _, err := m.Upload("original.txt", bytes.NewReader([]byte("original data"))); err != nil {
		t.Fatal(err)
	}
	moved := filepath.Join(dataDir, "old-device-root")
	if err := os.Rename(original, moved); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(original, 0700); err != nil {
		t.Fatal(err)
	}
	_, online = m.State()
	if online {
		t.Fatal("silent volume replacement reported online")
	}
	if _, err := m.Upload("must-not-be-written.txt", bytes.NewReader([]byte("invalid"))); !errors.Is(err, ErrOffline) {
		t.Fatalf("write after device change was not blocked: %v", err)
	}
	if _, err := os.Stat(filepath.Join(original, "must-not-be-written.txt")); !os.IsNotExist(err) {
		t.Fatalf("replacement device unexpectedly received data: %v", err)
	}
	if err := m.Reconnect(); !errors.Is(err, storageidentity.ErrMismatch) {
		t.Fatalf("same-name different directory attached by reconnect: %v", err)
	}
	m.Close()
	m, err = NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	if _, online := m.State(); online {
		t.Fatal("replacement attached after restart")
	}
	if err := m.Reconnect(); !errors.Is(err, storageidentity.ErrMismatch) {
		t.Fatalf("restart forgot binding: %v", err)
	}
	if err := transitionRootForTest(m, original); err != nil {
		t.Fatal("explicit owner reselection failed:", err)
	}
	_, online = m.State()
	if !online {
		t.Fatal("owner reselection did not attach new folder")
	}
	if _, _, err := m.Read("original.txt"); !os.IsNotExist(err) {
		t.Fatalf("old device file appeared in replacement: %v", err)
	}
	originalData, err := os.ReadFile(filepath.Join(moved, "original.txt"))
	if err != nil || string(originalData) != "original data" {
		t.Fatalf("original media damaged: %q %v", originalData, err)
	}
}
