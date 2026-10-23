package backup

import (
	"database/sql"
	"github.com/lengsukq/lightisle/core/internal/files"
	_ "github.com/mattn/go-sqlite3"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLiveSQLiteIncludedAndRestoreStagedSafely(t *testing.T) {
	dataDir := t.TempDir()
	share, err := files.NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer share.Close()
	db, err := sql.Open("sqlite3", filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err = db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("CREATE TABLE secrets (id INTEGER PRIMARY KEY,n TEXT)"); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("INSERT INTO secrets(n) VALUES('safe')"); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("CREATE TABLE sessions (id TEXT PRIMARY KEY)"); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("INSERT INTO sessions(id) VALUES('sensitive-cookie')"); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("CREATE TABLE file_shares (id TEXT PRIMARY KEY)"); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("INSERT INTO file_shares(id) VALUES('sensitive-share')"); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(`CREATE TABLE root_file_shares(
		id TEXT PRIMARY KEY, root_id TEXT NOT NULL, token_hash BLOB NOT NULL)`); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(`INSERT INTO root_file_shares(id,root_id,token_hash)
		VALUES('sensitive-root-share','0123456789abcdef0123456789abcdef',x'736563726574')`); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(dataDir, "shared-root.json"), []byte(`{"Path":"/tmp/something"}`), 0600); err != nil {
		t.Fatal(err)
	}
	rootRegistry := []byte(`{"version":1,"roots":[]}`)
	if err = os.WriteFile(filepath.Join(dataDir, "shared-roots.json"), rootRegistry, 0600); err != nil {
		t.Fatal(err)
	}
	home, _ := os.UserHomeDir()
	dest, err := os.MkdirTemp(home, "lightisle-p0-meta-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dest)
	svc := New(share, dataDir)
	defer svc.Close()
	if err = svc.StartBackup(dest); err != nil {
		t.Fatal(err)
	}
	backup := await(t, svc)
	if backup.LastError != "" {
		t.Fatalf("backup failed: %+v", backup)
	}
	manifestRoot, err := os.OpenRoot(backup.LastSnapshot)
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := parseManifest(manifestRoot)
	manifestRoot.Close()
	if err != nil || manifest.Format != format || len(manifest.Metadata) != 3 {
		t.Fatalf("metadata manifest: %+v %v", manifest, err)
	}
	if err = svc.StartRestore(backup.LastSnapshot); err != nil {
		t.Fatal(err)
	}
	restored := await(t, svc)
	if restored.LastError != "" || restored.RestoredMetadata == "" {
		t.Fatalf("restore failed: %+v", restored)
	}
	if got, err := os.ReadFile(filepath.Join(restored.RestoredMetadata, "shared-roots.json")); err != nil || string(got) != string(rootRegistry) {
		t.Fatalf("restored root registry mismatch: %q %v", got, err)
	}
	recoveredDB := filepath.Join(restored.RestoredMetadata, "accounts.sqlite")
	recovered, err := sql.Open("sqlite3", recoveredDB)
	if err != nil {
		t.Fatal(err)
	}
	defer recovered.Close()
	var name string
	if err = recovered.QueryRow("SELECT n FROM secrets WHERE id=1").Scan(&name); err != nil || name != "safe" {
		t.Fatalf("snapshot corrupted: %q %v", name, err)
	}
	var activeSessions int
	if err = recovered.QueryRow("SELECT COUNT(*) FROM sessions").Scan(&activeSessions); err != nil || activeSessions != 0 {
		t.Fatalf("backup restored active browser sessions: %d %v", activeSessions, err)
	}
	if err = db.QueryRow("SELECT COUNT(*) FROM sessions").Scan(&activeSessions); err != nil || activeSessions != 1 {
		t.Fatalf("snapshot redaction modified original sessions: %d %v", activeSessions, err)
	}
	var sharedTokens int
	if err = recovered.QueryRow("SELECT COUNT(*) FROM file_shares").Scan(&sharedTokens); err != nil || sharedTokens != 0 {
		t.Fatalf("backup resurrected download capabilities: %d %v", sharedTokens, err)
	}
	if err = recovered.QueryRow("SELECT COUNT(*) FROM root_file_shares").Scan(&sharedTokens); err != nil || sharedTokens != 0 {
		t.Fatalf("backup resurrected root file capabilities: %d %v", sharedTokens, err)
	}
	if err = db.QueryRow("SELECT COUNT(*) FROM file_shares").Scan(&sharedTokens); err != nil || sharedTokens != 1 {
		t.Fatalf("snapshot scrubbing changed live file shares: %d %v", sharedTokens, err)
	}
	if err = db.QueryRow("SELECT COUNT(*) FROM root_file_shares").Scan(&sharedTokens); err != nil || sharedTokens != 1 {
		t.Fatalf("snapshot scrubbing changed live root file shares: %d %v", sharedTokens, err)
	}
	// Existing live accounts cannot be overwritten by the restore operation.
	if err = db.QueryRow("SELECT n FROM secrets WHERE id=1").Scan(&name); err != nil || name != "safe" {
		t.Fatal("live DB changed")
	}
	if err = os.WriteFile(filepath.Join(backup.LastSnapshot, "metadata", "accounts.sqlite"), []byte("invalid"), 0600); err != nil {
		t.Fatal(err)
	}
	if err = svc.StartRestore(backup.LastSnapshot); err != nil {
		t.Fatal(err)
	}
	failure := await(t, svc)
	if !strings.Contains(failure.LastError, "metadata_checksum_mismatch") && !strings.Contains(failure.LastError, "file_changed_during_backup") {
		t.Fatalf("tampering accepted: %+v", failure)
	}
}
