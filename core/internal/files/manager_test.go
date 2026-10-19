package files

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestManagerShareSelectPersistenceAndOffline(t *testing.T) {
	base := t.TempDir()
	m, err := NewManager(base)
	if err != nil {
		t.Fatal(err)
	}
	if m.DisplayName() != "SharedFiles" {
		t.Fatalf("wrong initial share: %s", m.DisplayName())
	}
	if _, err := m.Upload("welcome.txt", strings.NewReader("hello")); err != nil {
		t.Fatal(err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := allowedSelectedFolder("/"); !errors.Is(err, ErrPath) {
		t.Fatalf("system root accepted: %v", err)
	}
	if _, err := allowedSelectedFolder(home); !errors.Is(err, ErrPath) {
		t.Fatalf("whole home accepted: %v", err)
	}
	dir, err := os.MkdirTemp(home, ".lightisle-manager-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	share := filepath.Join(dir, "share")
	if err := os.Mkdir(share, 0700); err != nil {
		t.Fatal(err)
	}
	if err := m.SetRoot(share); err != nil {
		t.Fatal(err)
	}
	if err := m.Mkdir("Photos"); err != nil {
		t.Fatal(err)
	}
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	m, err = NewManager(base)
	if err != nil {
		t.Fatal(err)
	}
	entries, err := m.List(".")
	if err != nil || len(entries) != 1 || entries[0].Name != "Photos" {
		t.Fatalf("selected share not persisted: %#v / %v", entries, err)
	}
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	offline := share + "-offline"
	if err := os.Rename(share, offline); err != nil {
		t.Fatal(err)
	}
	m, err = NewManager(base)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.List("."); !errors.Is(err, ErrOffline) {
		t.Fatalf("did not preserve offline state: %v", err)
	}
	if err := os.Rename(offline, share); err != nil {
		t.Fatal(err)
	}
	if err := m.Reconnect(); err != nil {
		t.Fatal(err)
	}
	if _, err := m.List("."); err != nil {
		t.Fatal(err)
	}
	m.Close()
}
