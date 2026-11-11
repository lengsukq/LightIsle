package cinema

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestScanSkipsAppleDoubleSidecarsAndOpenPurgesLegacySidecarRows(t *testing.T) {
	root := t.TempDir()
	dataDir := t.TempDir()
	store, err := files.NewManager(root)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	shareRoot, _ := store.State()

	moviesDir := filepath.Join(shareRoot, "影视")
	if err := os.MkdirAll(moviesDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(moviesDir, "黑豹2.2022.mp4"), []byte("real-video"), 0600); err != nil {
		t.Fatal(err)
	}
	// ExFAT AppleDouble sidecar and macOS hidden volume directories must never be indexed.
	if err := os.WriteFile(filepath.Join(moviesDir, "._黑豹2.2022.mp4"), []byte("appledouble"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(shareRoot, "._RootSidecar.mkv"), []byte("appledouble"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(shareRoot, ".Trashes"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(shareRoot, ".Trashes", "trashed.mp4"), []byte("trashed"), 0600); err != nil {
		t.Fatal(err)
	}

	lib, err := Open(dataDir, store)
	if err != nil {
		t.Fatal(err)
	}
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for lib.Status().Running && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if st := lib.Status(); st.Running || st.LastError != "" {
		t.Fatalf("scan status: %+v", st)
	}
	films, _, err := lib.List(1, "", "", 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(films) != 1 || films[0].Path != "影视/黑豹2.2022.mp4" {
		t.Fatalf("expected exactly 1 real film, got %+v", films)
	}

	// Simulate an existing ExFAT database polluted before this fix, then reopen.
	share, err := lib.share()
	if err != nil {
		t.Fatal(err)
	}
	_ = lib.Close()

	rawDB, err := sql.Open("sqlite3", filepath.Join(dataDir, "cinema.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := rawDB.Exec(`INSERT INTO films(share,path,title,kind,size,modified,seen) VALUES(?,?,?,?,4096,1,1)`,
		share, "影视/._黑豹2.2022.mp4", "黑豹2", "movie"); err != nil {
		rawDB.Close()
		t.Fatal(err)
	}
	rawDB.Close()

	reopened, err := Open(dataDir, store)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	filmsAfter, _, err := reopened.List(1, "", "", 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(filmsAfter) != 1 || filmsAfter[0].Path != "影视/黑豹2.2022.mp4" {
		t.Fatalf("expected reopen to purge AppleDouble duplicate row, got %+v", filmsAfter)
	}
}
