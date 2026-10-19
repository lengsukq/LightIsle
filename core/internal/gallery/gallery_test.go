package gallery

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestScanTimelineAlbumsFavoritesAndThumbnail(t *testing.T) {
	root := t.TempDir()
	storage, err := files.NewManager(root)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	imagePath := filepath.Join(root, "SharedFiles", "photo.png")
	f, err := os.Create(imagePath)
	if err != nil {
		t.Fatal(err)
	}
	picture := image.NewRGBA(image.Rect(0, 0, 42, 30))
	for y := 0; y < 30; y++ {
		for x := 0; x < 42; x++ {
			picture.Set(x, y, color.RGBA{80, 140, 210, 255})
		}
	}
	if err := png.Encode(f, picture); err != nil {
		t.Fatal(err)
	}
	f.Close()
	if err := os.WriteFile(filepath.Join(root, "SharedFiles", "video.mp4"), []byte("mock video"), 0600); err != nil {
		t.Fatal(err)
	}
	library, err := Open(root, storage)
	if err != nil {
		t.Fatal(err)
	}
	defer library.Close()
	if err := library.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for library.Status().Running && time.Now().Before(deadline) {
		time.Sleep(25 * time.Millisecond)
	}
	state := library.Status()
	if state.Running || state.LastError != "" {
		t.Fatalf("scan incomplete %+v", state)
	}
	count, err := library.Count()
	if err != nil || count != 2 {
		t.Fatalf("asset count %d %v", count, err)
	}
	assets, next, err := library.List(0, 1, 0, false)
	if err != nil || len(assets) != 1 || next == 0 {
		t.Fatalf("page1: %+v next %d %v", assets, next, err)
	}
	second, _, err := library.List(next, 1, 0, false)
	if err != nil || len(second) != 1 || second[0].ID == assets[0].ID {
		t.Fatalf("page2 %+v %v", second, err)
	}
	var photoID int64
	for _, asset := range append(assets, second...) {
		if asset.Type == "photo" {
			photoID = asset.ID
		}
	}
	if photoID == 0 {
		t.Fatal("png not indexed")
	}
	if err := library.Favorite(photoID, true); err != nil {
		t.Fatal(err)
	}
	favorites, _, err := library.List(0, 20, 0, true)
	if err != nil || len(favorites) != 1 || favorites[0].ID != photoID {
		t.Fatalf("favorites %+v %v", favorites, err)
	}
	album, err := library.CreateAlbum("家庭")
	if err != nil {
		t.Fatal(err)
	}
	if err := library.AddToAlbum(album.ID, photoID); err != nil {
		t.Fatal(err)
	}
	albumItems, _, err := library.List(0, 20, album.ID, false)
	if err != nil || len(albumItems) != 1 || albumItems[0].ID != photoID {
		t.Fatalf("album %+v %v", albumItems, err)
	}
	cached, err := library.Thumbnail(photoID)
	if err != nil {
		t.Fatal(err)
	}
	fi, err := cached.Stat()
	cached.Close()
	if err != nil || fi.Size() == 0 {
		t.Fatalf("thumbnail %v %v", fi, err)
	}
	if err := library.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(10 * time.Second)
	for library.Status().Running && time.Now().Before(deadline) {
		time.Sleep(25 * time.Millisecond)
	}
	again, _, err := library.List(0, 20, 0, true)
	if err != nil || len(again) != 1 {
		t.Fatalf("incremental lost favorite %+v %v", again, err)
	}
}
