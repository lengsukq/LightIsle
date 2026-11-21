package files

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestAllowedSelectedFolderRejectsSystemAndHomeRoots(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := allowedSelectedFolder("/"); !errors.Is(err, ErrPath) {
		t.Fatalf("expected system root rejection, got %v", err)
	}
	if _, err := allowedSelectedFolder(home); !errors.Is(err, ErrPath) {
		t.Fatalf("expected bare home directory rejection, got %v", err)
	}
	dir, err := os.MkdirTemp(home, ".lightisle-allowed-folder-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	if _, err := allowedSelectedFolder(dir); err != nil {
		t.Fatalf("expected subdirectory under home to be allowed, got %v", err)
	}
}

func TestMoveToTrashIfUnchangedAcceptsDirectoryTargets(t *testing.T) {
	root := t.TempDir()
	store, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	directory := filepath.Join(root, "folder")
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "inside.txt"), []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	handle, err := os.Open(directory)
	if err != nil {
		t.Fatal(err)
	}
	info, err := handle.Stat()
	_ = handle.Close()
	if err != nil {
		t.Fatal(err)
	}
	if err := store.MoveToTrashIfUnchanged("folder", info); err != nil {
		t.Fatalf("trash directory: %v", err)
	}
	if _, err := os.Stat(directory); !os.IsNotExist(err) {
		t.Fatalf("directory remained live after trash: %v", err)
	}
	entries, err := store.TrashList()
	if err != nil || len(entries) != 1 || entries[0].OriginalPath != "folder" {
		t.Fatalf("trash entries = %#v, %v", entries, err)
	}
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
	var persisted rootConfig
	bytes, _ := os.ReadFile(filepath.Join(data, "shared-root.json"))
	if json.Unmarshal(bytes, &persisted) != nil || persisted.Binding != nil {
		t.Fatal("owner confirmation was bypassed on disk")
	}
}
