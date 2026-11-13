package gallery

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestLivePhotoPairingMemoriesAndPersonShare(t *testing.T) {
	dataDir := t.TempDir()
	shareDir := filepath.Join(dataDir, "SharedFiles")

	userPhotos := filepath.Join(shareDir, "Users", "u1", "photos")
	if err := os.MkdirAll(userPhotos, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(userPhotos, "IMG_2048.JPG"), []byte("jpeg-still-bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(userPhotos, "IMG_2048.MOV"), []byte("mov-motion-bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	for i := 1; i <= 4; i++ {
		name := filepath.Join(userPhotos, "trip_"+string(rune('0'+i))+".jpg")
		if err := os.WriteFile(name, []byte("trip-photo"), 0600); err != nil {
			t.Fatal(err)
		}
	}

	store, err := files.NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	lib, err := Open(dataDir, store)
	if err != nil {
		t.Fatal(err)
	}
	defer lib.Close()

	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for lib.Status().Running && time.Now().Before(deadline) {
		time.Sleep(25 * time.Millisecond)
	}
	if st := lib.Status(); st.LastError != "" {
		t.Fatalf("scan failed: %s", st.LastError)
	}

	assets, _, err := lib.ListScopedForUserFiltered(1, 0, 50, 0, 0, false, false, PhotoFilter{}, []string{"Users/u1/photos"})
	if err != nil {
		t.Fatal(err)
	}
	var foundLive bool
	for _, a := range assets {
		if a.Name == "IMG_2048.MOV" {
			t.Fatalf("companion MOV should be folded out of default timeline")
		}
		if a.Name == "IMG_2048.JPG" {
			if a.LiveVideoAssetID <= 0 {
				t.Fatalf("expected LiveVideoAssetID > 0 on IMG_2048.JPG")
			}
			foundLive = true
			_, comp, err := lib.LiveVideoCompanion(a.ID)
			if err != nil || comp.Name != "IMG_2048.MOV" {
				t.Fatalf("unexpected companion: %+v, err=%v", comp, err)
			}
		}
	}
	if !foundLive {
		t.Fatal("IMG_2048.JPG not found in timeline")
	}

	memories, err := lib.MemoriesScoped(1, []string{"Users/u1/photos"})
	if err != nil {
		t.Fatal(err)
	}
	if len(memories) == 0 || memories[0].Kind != "live" {
		t.Fatalf("expected live memory card first, got %+v", memories)
	}

	// Verify read-only Vision person share scoping.
	shareKey, _ := lib.share()
	vec := make([]float32, 16)
	vec[0] = 1
	res, err := lib.db.Exec(`INSERT INTO asset_faces(asset_id, box_x, box_y, box_w, box_h, quality, eye_openness, model_version, embedding)
		VALUES(?, 0.1, 0.1, 0.3, 0.3, 0.9, 0.9, 'apple-anfr-v4-128f', ?)`,
		assets[0].ID, encodeFloat32Vector(vec))
	if err != nil {
		t.Fatal(err)
	}
	faceID, _ := res.LastInsertId()
	pres, err := lib.db.Exec(`INSERT INTO persons(share, user_id, model_version, name, cover_face_id, centroid, face_count, is_hidden, updated_at)
		VALUES(?, 1, 'apple-anfr-v4-128f', '宝宝', ?, ?, 1, 0, ?)`,
		shareKey, faceID, encodeFloat32Vector(vec), time.Now().Unix())
	if err != nil {
		t.Fatal(err)
	}
	personID, _ := pres.LastInsertId()
	_, _ = lib.db.Exec(`INSERT INTO person_face_links(user_id, face_id, person_id) VALUES(1, ?, ?)`, faceID, personID)

	ps, err := lib.CreateOrUpdatePersonShare(1, personID, 2, "宝宝成长流", 0, []string{"Users/u1/photos"})
	if err != nil {
		t.Fatal(err)
	}
	sharedAssets, _, _, err := lib.ListPersonShareAssets(2, ps.ID, 0, 20)
	if err != nil || len(sharedAssets) != 1 || sharedAssets[0].ID != assets[0].ID {
		t.Fatalf("expected 1 shared asset for member 2, got %+v (err=%v)", sharedAssets, err)
	}
	if _, _, err := lib.AuthorizePersonShareAssetWithOwner(3, ps.ID, assets[0].ID); err == nil {
		t.Fatal("unauthorized user 3 must not access person share")
	}
	_ = context.Background()
}
