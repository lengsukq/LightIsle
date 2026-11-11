package gallery

import (
	"database/sql"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestGallerySkipsAppleDoubleSidecarsAndOpenPurgesLegacySidecarRows(t *testing.T) {
	root := t.TempDir()
	dataDir := t.TempDir()
	store, err := files.NewManager(root)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	shareRoot, _ := store.State()

	photosDir := filepath.Join(shareRoot, "图库")
	if err := os.MkdirAll(photosDir, 0700); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(filepath.Join(photosDir, "shot.png"))
	if err != nil {
		t.Fatal(err)
	}
	pic := image.NewRGBA(image.Rect(0, 0, 16, 16))
	pic.Set(0, 0, color.RGBA{10, 20, 30, 255})
	if err := png.Encode(f, pic); err != nil {
		f.Close()
		t.Fatal(err)
	}
	f.Close()
	if err := os.WriteFile(filepath.Join(photosDir, "._shot.png"), []byte("appledouble"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(shareRoot, ".Spotlight-V100"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(shareRoot, ".Spotlight-V100", "index.jpg"), []byte("hidden"), 0600); err != nil {
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
	assets, _, err := lib.List(0, 50, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(assets) != 1 || assets[0].Path != "图库/shot.png" {
		t.Fatalf("expected 1 real photo, got %+v", assets)
	}

	share, err := lib.share()
	if err != nil {
		t.Fatal(err)
	}
	_ = lib.Close()

	rawDB, err := sql.Open("sqlite3", filepath.Join(dataDir, "gallery.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := rawDB.Exec(`INSERT INTO assets(share,path,type,size,modified,taken_at,seen) VALUES(?,?,?,?,1,1,1)`,
		share, "图库/._shot.png", "photo", 4096); err != nil {
		rawDB.Close()
		t.Fatal(err)
	}
	rawDB.Close()

	reopened, err := Open(dataDir, store)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	assetsAfter, _, err := reopened.List(0, 50, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(assetsAfter) != 1 || assetsAfter[0].Path != "图库/shot.png" {
		t.Fatalf("expected reopen to purge AppleDouble asset row, got %+v", assetsAfter)
	}
}
