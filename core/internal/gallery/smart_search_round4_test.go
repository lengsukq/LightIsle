package gallery

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

func TestRound4SmartSearchMultiKeywordAlbumsYearAndSingleChar(t *testing.T) {
	root := t.TempDir()
	storage, err := files.NewManager(root)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()

	shareRoot := filepath.Join(root, "SharedFiles")
	t2026 := time.Date(2026, 5, 10, 12, 0, 0, 0, time.Local)
	t2024 := time.Date(2024, 8, 20, 12, 0, 0, 0, time.Local)

	writeTestPNG(t, filepath.Join(shareRoot, "Photos", "IMG_2026_beach.png"), t2026)
	writeTestPNG(t, filepath.Join(shareRoot, "Photos", "IMG_2024_beach.png"), t2024)
	writeTestPNG(t, filepath.Join(shareRoot, "Photos", "fireworks_night.png"), t2026.Add(time.Minute))
	writeTestPNG(t, filepath.Join(shareRoot, "Photos", "spring_blossom.png"), t2026.Add(2*time.Minute))
	if err := os.MkdirAll(filepath.Join(shareRoot, "Photos"), 0o700); err != nil {
		t.Fatal(err)
	}
	clipPath := filepath.Join(shareRoot, "Photos", "family_clip.mp4")
	if err := os.WriteFile(clipPath, []byte("fake-video"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(clipPath, t2026, t2026); err != nil {
		t.Fatal(err)
	}

	analyzer := &fakeAIAnalyzer{
		byName: map[string]mediaworker.AIAnalysis{
			"IMG_2026_beach.png": {
				Status:    "ok",
				SceneTags: []mediaworker.AISceneTag{{Label: "beach", Confidence: 0.92}},
			},
			"IMG_2024_beach.png": {
				Status:    "ok",
				SceneTags: []mediaworker.AISceneTag{{Label: "beach", Confidence: 0.90}},
			},
			"fireworks_night.png": {
				Status:    "ok",
				SceneTags: []mediaworker.AISceneTag{{Label: "night_sky", Confidence: 0.91}},
			},
			"spring_blossom.png": {
				Status:    "ok",
				SceneTags: []mediaworker.AISceneTag{{Label: "flower", Confidence: 0.95}},
			},
		},
	}

	lib, err := Open(t.TempDir(), storage)
	if err != nil {
		t.Fatal(err)
	}
	defer lib.Close()
	lib.SetAIAnalyzer(analyzer)

	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitForScanAndAIIndex(t, lib)

	// Force taken_at years and video duration_seconds in SQLite so temporal and video badge fields are deterministic.
	if _, err := lib.db.Exec(`UPDATE assets SET taken_at=? WHERE path LIKE '%IMG_2026_beach.png'`, t2026.Unix()); err != nil {
		t.Fatal(err)
	}
	if _, err := lib.db.Exec(`UPDATE assets SET taken_at=? WHERE path LIKE '%IMG_2024_beach.png'`, t2024.Unix()); err != nil {
		t.Fatal(err)
	}
	var videoID, blossomID int64
	if err := lib.db.QueryRow(`SELECT id FROM assets WHERE path='Photos/family_clip.mp4'`).Scan(&videoID); err != nil {
		t.Fatal(err)
	}
	if err := lib.db.QueryRow(`SELECT id FROM assets WHERE path='Photos/spring_blossom.png'`).Scan(&blossomID); err != nil {
		t.Fatal(err)
	}
	if _, err := lib.db.Exec(`UPDATE assets SET duration_seconds=88.5, taken_at=? WHERE id=?`, t2026.Unix(), videoID); err != nil {
		t.Fatal(err)
	}

	album, err := lib.CreateAlbum("三亚家庭相册")
	if err != nil {
		t.Fatal(err)
	}
	if err := lib.AddToAlbum(album.ID, videoID); err != nil {
		t.Fatal(err)
	}

	privAlbum, err := lib.CreatePrivateAlbum(1, "秘密花园")
	if err != nil {
		t.Fatal(err)
	}
	if err := lib.AddToPrivateAlbum(1, privAlbum.ID, blossomID); err != nil {
		t.Fatal(err)
	}

	// 1. Multi-keyword year + scene ("2026 海边") hits only the 2026 beach photo, not 2024!
	hits2026Beach, _, err := lib.ListScopedForUserFiltered(1, 0, 20, 0, 0, false, false, PhotoFilter{Query: "2026 海边"}, []string{"."})
	if err != nil || len(hits2026Beach) != 1 || hits2026Beach[0].Name != "IMG_2026_beach.png" {
		t.Fatalf("expected only IMG_2026_beach.png for '2026 海边', got %+v err=%v", hits2026Beach, err)
	}

	// 2. Single-char Chinese scene ("海" and "花") works, while compound "烟花" does NOT hijack 1-char "花"!
	hitsSea, _, err := lib.ListScopedForUserFiltered(1, 0, 20, 0, 0, false, false, PhotoFilter{Query: "海"}, []string{"."})
	if err != nil || len(hitsSea) != 2 {
		t.Fatalf("expected 2 beach photos for single-char '海', got %+v err=%v", hitsSea, err)
	}
	hitsFireworks, _, err := lib.ListScopedForUserFiltered(1, 0, 20, 0, 0, false, false, PhotoFilter{Query: "烟花"}, []string{"."})
	if err != nil || len(hitsFireworks) != 1 || hitsFireworks[0].Name != "fireworks_night.png" {
		t.Fatalf("expected only fireworks_night.png for '烟花', got %+v err=%v", hitsFireworks, err)
	}

	// 3. Album name + media type ("三亚家庭 视频") hits family_clip.mp4 and returns durationSeconds=88.5!
	hitsAlbumVideo, _, err := lib.ListScopedForUserFiltered(1, 0, 20, 0, 0, false, false, PhotoFilter{Query: "三亚家庭 视频"}, []string{"."})
	if err != nil || len(hitsAlbumVideo) != 1 || hitsAlbumVideo[0].ID != videoID || hitsAlbumVideo[0].DurationSeconds != 88.5 {
		t.Fatalf("expected family_clip.mp4 with durationSeconds=88.5, got %+v err=%v", hitsAlbumVideo, err)
	}

	// 4. Private album name ("秘密花园 花") matches for owner user 1, and NEVER leaks to user 2!
	hitsPrivOwner, _, err := lib.ListScopedForUserFiltered(1, 0, 20, 0, 0, false, false, PhotoFilter{Query: "秘密花园 花"}, []string{"."})
	if err != nil || len(hitsPrivOwner) != 1 || hitsPrivOwner[0].ID != blossomID {
		t.Fatalf("expected owner private album match, got %+v err=%v", hitsPrivOwner, err)
	}
	hitsPrivOther, _, err := lib.ListScopedForUserFiltered(2, 0, 20, 0, 0, false, false, PhotoFilter{Query: "秘密花园 花"}, []string{"."})
	if err != nil || len(hitsPrivOther) != 0 {
		t.Fatalf("private album name leaked to user 2: %+v err=%v", hitsPrivOther, err)
	}
}
