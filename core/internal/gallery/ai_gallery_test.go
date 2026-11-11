package gallery

import (
	"context"
	"encoding/binary"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

type fakeAIAnalyzer struct {
	byName map[string]mediaworker.AIAnalysis
}

func (f *fakeAIAnalyzer) AnalyzeBatch(_ context.Context, items []mediaworker.AIBatchInput) ([]mediaworker.AIAnalysis, error) {
	out := make([]mediaworker.AIAnalysis, len(items))
	for i, it := range items {
		if res, ok := f.byName[it.Name]; ok {
			out[i] = res
		} else {
			out[i] = mediaworker.AIAnalysis{Status: "ok"}
		}
	}
	return out, nil
}

func writeTestPNG(t *testing.T, fullPath string, modTime time.Time) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(fullPath), 0700); err != nil {
		t.Fatal(err)
	}
	file, err := os.Create(fullPath)
	if err != nil {
		t.Fatal(err)
	}
	img := image.NewRGBA(image.Rect(0, 0, 120, 120))
	for y := 0; y < 120; y++ {
		for x := 0; x < 120; x++ {
			img.Set(x, y, color.RGBA{uint8(x * 2), uint8(y * 2), 180, 255})
		}
	}
	if err := png.Encode(file, img); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	_ = file.Close()
	if err := os.Chtimes(fullPath, modTime, modTime); err != nil {
		t.Fatal(err)
	}
}

func testFaceVec(axis int, jitter float32) []byte {
	vec := make([]float32, 32)
	vec[axis] = 1.0
	vec[(axis+1)%32] = jitter
	var normSq float64
	for _, v := range vec {
		normSq += float64(v * v)
	}
	norm := float32(math.Sqrt(normSq))
	for i := range vec {
		vec[i] /= norm
	}
	return encodeFloat32Vector(vec)
}

func testFeaturePrintF16(axis int, delta float32) []byte {
	vals := make([]float32, 16)
	vals[axis] = 1.0
	vals[(axis+1)%16] = delta
	raw := make([]byte, len(vals)*2)
	for i, v := range vals {
		binary.LittleEndian.PutUint16(raw[i*2:(i+1)*2], float32ToFloat16BitsTest(v))
	}
	return raw
}

func float32ToFloat16BitsTest(f float32) uint16 {
	if f == 0 {
		return 0
	}
	bits := math.Float32bits(f)
	sign := uint16((bits >> 16) & 0x8000)
	exp := int((bits>>23)&0xFF) - 127 + 15
	mant := uint16((bits >> 13) & 0x03FF)
	if exp <= 0 {
		return sign
	}
	if exp >= 31 {
		return sign | 0x7C00
	}
	return sign | (uint16(exp) << 10) | mant
}

func waitForScanAndAIIndex(t *testing.T, lib *Library) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		st := lib.Status()
		if !st.Running && (st.AIIndexing == nil || (!st.AIIndexing.Running && st.AIIndexing.Remaining == 0)) {
			// Verify all photos have ai_index_state rows.
			share, err := lib.share()
			if err == nil {
				rem, _ := lib.nextAIBatch(share, 1)
				if len(rem) == 0 {
					return
				}
			}
		}
		lib.TriggerAIIndex()
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for AI index: %+v", lib.Status())
}

func TestAIIndexOCRSemanticSearchPersonsAndSimilarCleanup(t *testing.T) {
	root := t.TempDir()
	storage, err := files.NewManager(root)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()

	baseTime := time.Date(2026, 8, 15, 18, 0, 0, 0, time.UTC)
	shareRoot := filepath.Join(root, "SharedFiles")
	writeTestPNG(t, filepath.Join(shareRoot, "SharedPhotos", "sunset_beach.png"), baseTime)
	writeTestPNG(t, filepath.Join(shareRoot, "SharedPhotos", "sunset_city.png"), baseTime.Add(-10*time.Minute))
	writeTestPNG(t, filepath.Join(shareRoot, "SharedPhotos", "invoice_2026.png"), baseTime.Add(-20*time.Minute))
	writeTestPNG(t, filepath.Join(shareRoot, "Users", "u1", "Photos", "baby_burst_1.png"), baseTime.Add(1*time.Second))
	writeTestPNG(t, filepath.Join(shareRoot, "Users", "u1", "Photos", "baby_burst_2.png"), baseTime.Add(2*time.Second))
	writeTestPNG(t, filepath.Join(shareRoot, "Users", "u2", "Photos", "u2_private_face.png"), baseTime.Add(5*time.Second))

	aestheticsGood := float32(0.75)
	aestheticsSoft := float32(0.15)
	analyzer := &fakeAIAnalyzer{
		byName: map[string]mediaworker.AIAnalysis{
			"sunset_beach.png": {
				Status: "ok",
				SceneTags: []mediaworker.AISceneTag{
					{Label: "beach", Confidence: 0.91},
					{Label: "sunset_sunrise", Confidence: 0.88},
				},
				FeaturePrintF16: testFeaturePrintF16(1, 0),
				Sharpness:       0.62,
			},
			"sunset_city.png": {
				Status: "ok",
				SceneTags: []mediaworker.AISceneTag{
					{Label: "building", Confidence: 0.85},
					{Label: "sunset_sunrise", Confidence: 0.84},
				},
				FeaturePrintF16: testFeaturePrintF16(2, 0),
				Sharpness:       0.58,
			},
			"invoice_2026.png": {
				Status:    "ok",
				OCRText:   "广东增值税电子普通发票 金额 ¥1280.00 合同编号 HT-9981",
				OCRTokens: []string{"广东", "增值税", "电子", "普通", "发票", "ht-9981", "1280"},
				SceneTags: []mediaworker.AISceneTag{
					{Label: "receipt", Confidence: 0.93},
				},
				FeaturePrintF16: testFeaturePrintF16(3, 0),
				Sharpness:       0.80,
			},
			"baby_burst_1.png": {
				Status: "ok",
				Faces: []mediaworker.AIFace{
					{BoxX: 0.25, BoxY: 0.20, BoxW: 0.40, BoxH: 0.40, Quality: 0.72, EyeOpenness: 0.12, ModelVersion: "anfr-v4-f32x128", Embedding: testFaceVec(0, 0.02)},
				},
				FeaturePrintF16: testFeaturePrintF16(5, 0.01),
				Sharpness:       0.35,
				Aesthetics:      &aestheticsSoft,
			},
			"baby_burst_2.png": {
				Status: "ok",
				Faces: []mediaworker.AIFace{
					{BoxX: 0.26, BoxY: 0.21, BoxW: 0.40, BoxH: 0.40, Quality: 0.89, EyeOpenness: 0.82, ModelVersion: "anfr-v4-f32x128", Embedding: testFaceVec(0, 0.04)},
					{BoxX: 0.65, BoxY: 0.25, BoxW: 0.25, BoxH: 0.25, Quality: 0.78, EyeOpenness: 0.75, ModelVersion: "anfr-v4-f32x128", Embedding: testFaceVec(3, 0.01)},
				},
				FeaturePrintF16: testFeaturePrintF16(5, 0.02),
				Sharpness:       0.84,
				Aesthetics:      &aestheticsGood,
			},
			"u2_private_face.png": {
				Status: "ok",
				Faces: []mediaworker.AIFace{
					{BoxX: 0.20, BoxY: 0.20, BoxW: 0.45, BoxH: 0.45, Quality: 0.92, EyeOpenness: 0.88, ModelVersion: "anfr-v4-f32x128", Embedding: testFaceVec(7, 0.0)},
				},
				FeaturePrintF16: testFeaturePrintF16(9, 0),
				Sharpness:       0.77,
			},
		},
	}

	stateDir := t.TempDir()
	lib, err := Open(stateDir, storage)
	if err != nil {
		t.Fatal(err)
	}
	defer lib.Close()

	// Pause toggle works cleanly before and after scan.
	lib.SetAIPaused(true)
	if !lib.AIPaused() {
		t.Fatal("expected AI paused")
	}
	lib.SetAIPaused(false)
	lib.SetAIAnalyzer(analyzer)

	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitForScanAndAIIndex(t, lib)

	u1Roots := []string{"SharedPhotos", "Users/u1"}
	u2Roots := []string{"SharedPhotos", "Users/u2"}

	// 1. Multi-concept natural language search: "海边日落" matches ONLY sunset_beach.png (not sunset_city.png).
	hits, _, err := lib.ListScopedForUserFiltered(1, 0, 20, 0, 0, false, false, PhotoFilter{
		Query: "海边日落", SearchMode: "scene",
	}, u1Roots)
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 1 || hits[0].Name != "sunset_beach.png" {
		t.Fatalf("expected only sunset_beach.png for 海边日落, got %+v", hits)
	}

	// 2. Offline OCR search: search by contract number "HT-9981" and verify Live Text detail.
	ocrHits, _, err := lib.ListScopedForUserFiltered(1, 0, 20, 0, 0, false, false, PhotoFilter{
		Query: "HT-9981", SearchMode: "ocr",
	}, u1Roots)
	if err != nil || len(ocrHits) != 1 || ocrHits[0].Name != "invoice_2026.png" {
		t.Fatalf("expected invoice_2026.png from OCR search, got %+v err=%v", ocrHits, err)
	}
	detail, err := lib.AssetAIDetailScoped(1, ocrHits[0].ID, u1Roots)
	if err != nil || !detail.Indexed || detail.OCRText == "" {
		t.Fatalf("unexpected AI detail: %+v err=%v", detail, err)
	}

	// 3. Per-user person clustering & strict privacy isolation between u1 and u2.
	u1Persons, err := lib.ListPersonsScoped(1, false, u1Roots)
	if err != nil {
		t.Fatal(err)
	}
	// u1 sees 2 clusters from u1's burst photos (baby face + second person), NEVER u2's private face!
	if len(u1Persons) != 2 {
		t.Fatalf("expected 2 person clusters for u1, got %+v", u1Persons)
	}
	u2Persons, err := lib.ListPersonsScoped(2, false, u2Roots)
	if err != nil {
		t.Fatal(err)
	}
	if len(u2Persons) != 1 {
		t.Fatalf("expected 1 private person cluster for u2, got %+v", u2Persons)
	}

	// Rename u1's main cluster (2 photos) to "宝宝", filter timeline by PersonID and by person name.
	babyCluster := u1Persons[0]
	if babyCluster.PhotoCount != 2 {
		t.Fatalf("expected baby cluster to group both burst photos, got %+v", babyCluster)
	}
	babyName := "宝宝"
	if err := lib.UpdatePerson(1, babyCluster.ID, &babyName, nil); err != nil {
		t.Fatal(err)
	}
	// User 2 cannot rename User 1's person cluster.
	evilName := "越权修改"
	if err := lib.UpdatePerson(2, babyCluster.ID, &evilName, nil); err == nil {
		t.Fatal("expected cross-user person update to fail")
	}

	personPhotos, _, err := lib.ListScopedForUserFiltered(1, 0, 20, 0, 0, false, false, PhotoFilter{
		PersonID: babyCluster.ID,
	}, u1Roots)
	if err != nil || len(personPhotos) != 2 {
		t.Fatalf("expected 2 photos for babyCluster, got %+v err=%v", personPhotos, err)
	}
	smartNameHits, _, err := lib.ListScopedForUserFiltered(1, 0, 20, 0, 0, false, false, PhotoFilter{
		Query: "宝宝", SearchMode: "all",
	}, u1Roots)
	if err != nil || len(smartNameHits) != 2 {
		t.Fatalf("expected smart search '宝宝' to match 2 person photos, got %+v err=%v", smartNameHits, err)
	}

	// Render circular face avatar crop JPEG.
	faceAsset, box, err := lib.FaceAssetAndBox(babyCluster.CoverFaceID)
	if err != nil {
		t.Fatal(err)
	}
	avatarJPEG, err := lib.RenderFaceAvatarJPEG(context.Background(), faceAsset.ID, box)
	if err != nil || len(avatarJPEG) < 64 {
		t.Fatalf("expected non-empty avatar JPEG, len=%d err=%v", len(avatarJPEG), err)
	}

	// Merge second cluster into babyCluster and verify hide/unhide.
	if err := lib.MergePersons(1, u1Persons[1].ID, babyCluster.ID); err != nil {
		t.Fatal(err)
	}
	hideTrue := true
	if err := lib.UpdatePerson(1, babyCluster.ID, nil, &hideTrue); err != nil {
		t.Fatal(err)
	}
	visibleAfterHide, err := lib.ListPersonsScoped(1, false, u1Roots)
	if err != nil || len(visibleAfterHide) != 0 {
		t.Fatalf("expected 0 visible persons after hide, got %+v err=%v", visibleAfterHide, err)
	}
	allIncludingHidden, err := lib.ListPersonsScoped(1, true, u1Roots)
	if err != nil || len(allIncludingHidden) != 1 || !allIncludingHidden[0].Hidden {
		t.Fatalf("expected 1 hidden person when includeHidden=true, got %+v err=%v", allIncludingHidden, err)
	}

	// 4. Burst & similar photo cleanup: recommends baby_burst_2.png (eyes open + sharp) over baby_burst_1.png (closed eyes + soft).
	groups, err := lib.FindSimilarGroupsScoped(u1Roots, 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 1 || groups[0].Kind != "burst" || len(groups[0].Items) != 2 {
		t.Fatalf("expected 1 burst group of 2 photos, got %+v", groups)
	}
	var recommendedName string
	for _, it := range groups[0].Items {
		if it.Recommended {
			recommendedName = it.Name
		}
	}
	if recommendedName != "baby_burst_2.png" {
		t.Fatalf("expected baby_burst_2.png as Best-Shot, got %q (group=%+v)", recommendedName, groups[0])
	}
}
