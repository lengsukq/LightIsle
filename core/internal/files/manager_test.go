package files

import (
	"encoding/json"
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

func TestLegacyExternalRootRequiresReselectionWithoutFallback(t *testing.T) {
	data := t.TempDir()
	external := t.TempDir()
	config, _ := json.Marshal(map[string]string{"path": external})
	if err := os.WriteFile(filepath.Join(data, "shared-root.json"), config, 0600); err != nil {
		t.Fatal(err)
	}
	m, err := NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	where, online := m.State()
	if where != external || online {
		t.Fatalf("legacy root silently rebound: %q %v", where, online)
	}
	if err := m.Reconnect(); !errors.Is(err, ErrRootConfirmation) {
		t.Fatalf("unconfirmed root accepted: %v", err)
	}
	if _, err := os.Stat(filepath.Join(data, "SharedFiles")); !os.IsNotExist(err) {
		t.Fatalf("unexpected default fallback created: %v", err)
	}
}

func TestLegacyDefaultRootAlsoRequiresOwnerConfirmation(t *testing.T) {
	data := t.TempDir()
	location := filepath.Join(data, "SharedFiles")
	if err := os.Mkdir(location, 0700); err != nil {
		t.Fatal(err)
	}
	config, _ := json.Marshal(map[string]string{"path": location})
	if err := os.WriteFile(filepath.Join(data, "shared-root.json"), config, 0600); err != nil {
		t.Fatal(err)
	}
	m, err := NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	if _, online := m.State(); online {
		t.Fatal("legacy default path silently gained a physical binding")
	}
	if err := m.Reconnect(); !errors.Is(err, ErrRootConfirmation) {
		t.Fatalf("path-only default accepted: %v", err)
	}
	var persisted rootConfig
	bytes, _ := os.ReadFile(filepath.Join(data, "shared-root.json"))
	if json.Unmarshal(bytes, &persisted) != nil || persisted.Binding != nil {
		t.Fatal("owner confirmation was bypassed on disk")
	}
}

func TestOwnerSelectionCannotShareAccountDatabaseDirectory(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	base, err := os.MkdirTemp(home, ".lightisle-private-boundary-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(base)
	data := filepath.Join(base, "private")
	if err := os.Mkdir(data, 0700); err != nil {
		t.Fatal(err)
	}
	m, err := NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	if err := os.WriteFile(filepath.Join(data, "accounts.sqlite"), []byte("private fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, location := range []string{base, data} {
		if err := m.SetRoot(location); !errors.Is(err, ErrPath) {
			t.Fatalf("metadata parent accepted as shared root: %s %v", location, err)
		}
	}
	if _, _, err := m.Read("accounts.sqlite"); !os.IsNotExist(err) {
		t.Fatalf("private metadata became readable: %v", err)
	}
	if err := m.SetRoot(filepath.Join(data, "SharedFiles")); err != nil {
		t.Fatalf("safe existing default root rejected: %v", err)
	}
}

func TestShareConfigSyncFailureRequiresRestartBeforeAccess(t *testing.T) {
	data := t.TempDir()
	m, err := NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.Upload("old.txt", strings.NewReader("original")); err != nil {
		t.Fatal(err)
	}
	home, _ := os.UserHomeDir()
	selected, err := os.MkdirTemp(home, ".lightisle-sync-failure-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(selected)
	m.syncRootDirectory = func(*os.File) error { return errors.New("simulated parent sync failure") }
	if err := m.SetRoot(selected); !errors.Is(err, ErrRootPersistence) {
		t.Fatalf("ambiguous publication was not reported: %v", err)
	}
	if _, online := m.State(); online {
		t.Fatal("old in-memory root remained accessible")
	}
	if _, err := m.List("."); !errors.Is(err, ErrOffline) {
		t.Fatalf("access continued: %v", err)
	}
	if err := m.Reconnect(); !errors.Is(err, ErrRootPersistence) {
		t.Fatalf("retry bypassed uncertain state: %v", err)
	}
	m.Close()
	reloaded, err := NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer reloaded.Close()
	canonical, _ := filepath.EvalSymlinks(selected)
	if location, online := reloaded.State(); location != canonical || !online {
		t.Fatalf("restart did not read published selection: %q %v", location, online)
	}
	if original, err := os.ReadFile(filepath.Join(data, "SharedFiles", "old.txt")); err != nil || string(original) != "original" {
		t.Fatal("saving a selection modified original data")
	}
}
