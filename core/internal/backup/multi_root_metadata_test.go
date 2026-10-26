package backup

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	_ "github.com/mattn/go-sqlite3"
)

func writeMetadataSQLite(t *testing.T, name string, statements ...string) {
	t.Helper()
	db, err := sql.Open("sqlite3", name)
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range statements {
		if _, err := db.Exec(statement); err != nil {
			db.Close()
			t.Fatalf("exec %q: %v", statement, err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
}

func writeTaskMetadataSQLite(t *testing.T, name string) {
	t.Helper()
	writeMetadataSQLite(t, name,
		`CREATE TABLE task_journal(id INTEGER PRIMARY KEY,running INTEGER,processed INTEGER,bytes INTEGER,
		 started_at INTEGER,last_done INTEGER,last_error TEXT)`,
		`INSERT INTO task_journal VALUES(1,1,7,8,9,10,'live')`,
		`CREATE TABLE task_runs(id INTEGER PRIMARY KEY,running INTEGER)`,
		`INSERT INTO task_runs VALUES(1,1),(2,0)`,
	)
}

func TestBackupMetadataBoundsAndCapturesSixteenRegisteredRootDatabases(t *testing.T) {
	dataDir := t.TempDir()
	rootIDs := make([]string, maxRegisteredMetadataRoots)
	roots := make([]map[string]string, 0, len(rootIDs))
	for i := range rootIDs {
		id := fmt.Sprintf("%032x", i+1)
		rootIDs[i] = id
		roots = append(roots, map[string]string{"rootID": id})
	}
	registry, err := json.Marshal(struct {
		Version int                 `json:"version"`
		Roots   []map[string]string `json:"roots"`
	}{Version: 1, Roots: roots})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dataDir, "shared-roots.json"), registry, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dataDir, "shared-root.json"), []byte(`{"path":"/private/root"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dataDir, "config-backup-schedule.json"), []byte(`{"version":1}`), 0600); err != nil {
		t.Fatal(err)
	}
	writeMetadataSQLite(t, filepath.Join(dataDir, "accounts.sqlite"), `CREATE TABLE users(id INTEGER)`)
	writeMetadataSQLite(t, filepath.Join(dataDir, "gallery.sqlite"), `CREATE TABLE assets(id INTEGER)`)
	writeMetadataSQLite(t, filepath.Join(dataDir, "cinema.sqlite"), `CREATE TABLE films(id INTEGER)`)
	writeTaskMetadataSQLite(t, filepath.Join(dataDir, "tasks.sqlite"))
	for _, id := range rootIDs {
		writeMetadataSQLite(t, filepath.Join(dataDir, rootMetadataName("gallery", id)), `CREATE TABLE assets(id INTEGER)`)
		writeMetadataSQLite(t, filepath.Join(dataDir, rootMetadataName("cinema", id)), `CREATE TABLE films(id INTEGER)`)
		writeTaskMetadataSQLite(t, filepath.Join(dataDir, rootMetadataName("tasks", id)))
	}

	snapshotDir := t.TempDir()
	snapshot, err := os.OpenRoot(snapshotDir)
	if err != nil {
		t.Fatal(err)
	}
	defer snapshot.Close()
	manifest := &Manifest{}
	service := New(nil, dataDir)
	defer service.Close()
	if err := service.backupMetadata(context.Background(), snapshot, "snapshot", manifest); err != nil {
		t.Fatal(err)
	}
	if len(manifest.Metadata) != maxMetadataEntries {
		t.Fatalf("metadata entries=%d, want bounded maximum %d", len(manifest.Metadata), maxMetadataEntries)
	}
	if err := validateMetadataCatalog(manifest.Metadata, rootIDs); err != nil {
		t.Fatalf("full registered catalog rejected: %v", err)
	}
	snapshotFiles, err := os.OpenRoot(filepath.Join(snapshotDir, "snapshot"))
	if err != nil {
		t.Fatal(err)
	}
	defer snapshotFiles.Close()
	gotIDs, err := metadataRootIDsFromSnapshot(context.Background(), snapshotFiles, manifest.Metadata)
	if err != nil || len(gotIDs) != maxRegisteredMetadataRoots {
		t.Fatalf("snapshot root registry ids=%d err=%v", len(gotIDs), err)
	}
	for i := range gotIDs {
		if gotIDs[i] != rootIDs[i] {
			t.Fatalf("root registry id %d=%s, want %s", i, gotIDs[i], rootIDs[i])
		}
	}

	for _, kind := range []string{"gallery", "cinema", "tasks"} {
		name := rootMetadataName(kind, rootIDs[len(rootIDs)-1])
		if !containsMetadataFile(manifest.Metadata, name) {
			t.Errorf("last root database %s missing from snapshot", name)
		}
	}
	unregistered := append(append([]File(nil), manifest.Metadata...), File{
		Path: "gallery-root-ffffffffffffffffffffffffffffffff.sqlite", Size: 0,
		SHA256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
	})
	if err := validateMetadataCatalog(unregistered, rootIDs); err == nil {
		t.Fatal("unregistered root database was admitted to the catalog")
	}
}

func containsMetadataFile(entries []File, name string) bool {
	for _, entry := range entries {
		if entry.Path == name {
			return true
		}
	}
	return false
}

func TestRegisteredRootMetadataRejectsMoreThanSixteenAndInvalidIDs(t *testing.T) {
	dataDir := t.TempDir()
	for _, test := range []struct {
		name  string
		roots []map[string]string
	}{
		{name: "too_many", roots: func() []map[string]string {
			roots := make([]map[string]string, maxRegisteredMetadataRoots+1)
			for i := range roots {
				roots[i] = map[string]string{"rootID": fmt.Sprintf("%032x", i+1)}
			}
			return roots
		}()},
		{name: "invalid_id", roots: []map[string]string{{"rootID": "../../../accounts"}}},
	} {
		t.Run(test.name, func(t *testing.T) {
			registry, err := json.Marshal(struct {
				Version int                 `json:"version"`
				Roots   []map[string]string `json:"roots"`
			}{Version: 1, Roots: test.roots})
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dataDir, "shared-roots.json"), registry, 0600); err != nil {
				t.Fatal(err)
			}
			root, err := os.OpenRoot(dataDir)
			if err != nil {
				t.Fatal(err)
			}
			defer root.Close()
			if _, _, err := readRegisteredRootIDs(root); err == nil {
				t.Fatal("invalid registered roots accepted")
			}
		})
	}
	if err := os.WriteFile(filepath.Join(dataDir, "shared-roots.json"), []byte(`{"version":1}`), 0600); err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	if _, present, err := readRegisteredRootIDs(root); err == nil || !present {
		t.Fatalf("registry without roots array accepted: present=%v err=%v", present, err)
	}
}
