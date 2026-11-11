package server

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

type serverTestAIWorker struct {
	byName map[string]mediaworker.AIAnalysis
}

func (w *serverTestAIWorker) Probe(_ context.Context, _ *os.File, _ string) (mediaworker.Metadata, error) {
	return mediaworker.Metadata{Kind: "photo", MIME: "image/png", Width: 100, Height: 100}, nil
}

func (w *serverTestAIWorker) Poster(_ context.Context, _ *os.File, _ string, _ string) (mediaworker.Metadata, error) {
	return mediaworker.Metadata{}, mediaworker.ErrUnsupported
}

func (w *serverTestAIWorker) AnalyzeBatch(_ context.Context, items []mediaworker.AIBatchInput) ([]mediaworker.AIAnalysis, error) {
	out := make([]mediaworker.AIAnalysis, len(items))
	for i, it := range items {
		if res, ok := w.byName[it.Name]; ok {
			out[i] = res
		} else {
			out[i] = mediaworker.AIAnalysis{Status: "ok"}
		}
	}
	return out, nil
}

func writeServerTestPNG(t *testing.T, fullPath string, modTime time.Time) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(fullPath), 0700); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(fullPath)
	if err != nil {
		t.Fatal(err)
	}
	img := image.NewRGBA(image.Rect(0, 0, 100, 100))
	for y := 0; y < 100; y++ {
		for x := 0; x < 100; x++ {
			img.Set(x, y, color.RGBA{100, 150, 210, 255})
		}
	}
	if err := png.Encode(f, img); err != nil {
		_ = f.Close()
		t.Fatal(err)
	}
	_ = f.Close()
	if err := os.Chtimes(fullPath, modTime, modTime); err != nil {
		t.Fatal(err)
	}
}

func makeServerFaceBytes(axis int) []byte {
	raw := make([]byte, 32*4)
	binary.LittleEndian.PutUint32(raw[axis*4:(axis+1)*4], math.Float32bits(1.0))
	return raw
}

func makeServerFeatureF16(axis int) []byte {
	raw := make([]byte, 16*2)
	// IEEE 754 binary16 for 1.0 is 0x3C00
	binary.LittleEndian.PutUint16(raw[axis*2:(axis+1)*2], 0x3C00)
	return raw
}

func TestRootGalleryAIPersonsSimilarAndDuplicatesEndpoints(t *testing.T) {
	f := newRootRoutingFixture(t)

	// Allocate personal space on rootA for member, plus read/write grant on SharedAlbum.
	alloc := f.call(f.admin, http.MethodPost, rootRoute(f.rootA.ID, fmt.Sprintf("/users/%d/storage", f.memberID)), `{"categories":["files","photos","videos"]}`)
	if alloc.Code != http.StatusOK && alloc.Code != http.StatusCreated {
		t.Fatalf("allocate member storage: %d %s", alloc.Code, alloc.Body.String())
	}
	if err := os.MkdirAll(filepath.Join(f.pathA, "SharedAlbum"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootA.ID, "SharedAlbum", true); err != nil {
		t.Fatal(err)
	}

	ts := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	memberHome := filepath.Join(f.pathA, "Users", fmt.Sprintf("u%d", f.memberID))
	writeServerTestPNG(t, filepath.Join(memberHome, "photos", "member_burst_1.png"), ts)
	writeServerTestPNG(t, filepath.Join(memberHome, "photos", "member_burst_2.png"), ts.Add(1*time.Second))
	writeServerTestPNG(t, filepath.Join(f.pathA, "AdminSecret", "admin_only.png"), ts.Add(2*time.Second))

	// Duplicate files: one pair in member's space, and an identical copy in AdminSecret (must NOT leak to member!).
	dupContent := bytes.Repeat([]byte("Duplicate-Payload-Data-"), 500) // ~11.5 KiB
	for _, p := range []string{
		filepath.Join(memberHome, "files", "doc_v1.bin"),
		filepath.Join(memberHome, "files", "doc_v1_copy.bin"),
		filepath.Join(f.pathA, "AdminSecret", "admin_hidden_copy.bin"),
	} {
		if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, dupContent, 0600); err != nil {
			t.Fatal(err)
		}
	}

	// Initialize gallery service on rootA and wire AI worker.
	initResp := f.call(f.admin, http.MethodGet, rootRoute(f.rootA.ID, "/photos/status"), "")
	if initResp.Code != http.StatusOK {
		t.Fatalf("init gallery status: %d %s", initResp.Code, initResp.Body.String())
	}
	lib := f.services[f.rootA.ID].Gallery
	lib.SetMediaWorker(&serverTestAIWorker{
		byName: map[string]mediaworker.AIAnalysis{
			"member_burst_1.png": {
				Status:    "ok",
				OCRText:   "家庭电费账单 NO-7788",
				OCRTokens: []string{"家庭", "电费", "账单", "no-7788"},
				SceneTags: []mediaworker.AISceneTag{{Label: "receipt", Confidence: 0.9}},
				Faces: []mediaworker.AIFace{
					{BoxX: 0.2, BoxY: 0.2, BoxW: 0.4, BoxH: 0.4, Quality: 0.65, EyeOpenness: 0.15, ModelVersion: "anfr-v4-f32x128", Embedding: makeServerFaceBytes(1)},
				},
				FeaturePrintF16: makeServerFeatureF16(2),
				Sharpness:       0.32,
			},
			"member_burst_2.png": {
				Status:    "ok",
				SceneTags: []mediaworker.AISceneTag{{Label: "beach", Confidence: 0.92}, {Label: "sunset_sunrise", Confidence: 0.89}},
				Faces: []mediaworker.AIFace{
					{BoxX: 0.2, BoxY: 0.2, BoxW: 0.4, BoxH: 0.4, Quality: 0.90, EyeOpenness: 0.85, ModelVersion: "anfr-v4-f32x128", Embedding: makeServerFaceBytes(1)},
				},
				FeaturePrintF16: makeServerFeatureF16(2),
				Sharpness:       0.88,
			},
			"admin_only.png": {
				Status: "ok",
				Faces: []mediaworker.AIFace{
					{BoxX: 0.2, BoxY: 0.2, BoxW: 0.4, BoxH: 0.4, Quality: 0.95, EyeOpenness: 0.9, ModelVersion: "anfr-v4-f32x128", Embedding: makeServerFaceBytes(6)},
				},
				FeaturePrintF16: makeServerFeatureF16(7),
				Sharpness:       0.90,
			},
		},
	})

	// Scan gallery and wait for AI indexing to finish.
	scanResp := f.call(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/photos/scan"), "")
	if scanResp.Code != http.StatusAccepted {
		t.Fatalf("start scan: %d %s", scanResp.Code, scanResp.Body.String())
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		st := lib.Status()
		if !st.Running && (st.AIIndexing == nil || (!st.AIIndexing.Running && st.AIIndexing.Remaining == 0)) {
			resp := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/photos?q=NO-7788&searchMode=ocr"), "")
			if resp.Code == http.StatusOK && strings.Contains(resp.Body.String(), "member_burst_1.png") {
				break
			}
		}
		lib.TriggerAIIndex()
		time.Sleep(25 * time.Millisecond)
	}

	// Admin-only pause endpoint rejects member and works for admin.
	memberPause := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/photos/ai/pause"), `{"paused":true}`)
	if memberPause.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for member AI pause, got %d", memberPause.Code)
	}
	adminPause := f.call(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/photos/ai/pause"), `{"paused":false}`)
	if adminPause.Code != http.StatusOK {
		t.Fatalf("admin AI pause failed: %d %s", adminPause.Code, adminPause.Body.String())
	}

	// Semantic search & OCR search via /photos endpoint.
	sceneResp := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/photos?q=%E6%B5%B7%E8%BE%B9%E6%97%A5%E8%90%BD&searchMode=scene"), "")
	if sceneResp.Code != http.StatusOK || !strings.Contains(sceneResp.Body.String(), "member_burst_2.png") {
		t.Fatalf("semantic search failed: %d %s", sceneResp.Code, sceneResp.Body.String())
	}

	// Anti-oracle privacy check: member cannot probe admin's AdminSecret photo AI detail (404 not_found).
	adminPhotosResp := f.call(f.admin, http.MethodGet, rootRoute(f.rootA.ID, "/photos"), "")
	var adminList struct {
		Assets []struct {
			ID   int64  `json:"id"`
			Name string `json:"name"`
		} `json:"assets"`
	}
	_ = json.Unmarshal(adminPhotosResp.Body.Bytes(), &adminList)
	var adminAssetID int64
	for _, item := range adminList.Assets {
		if item.Name == "admin_only.png" {
			adminAssetID = item.ID
		}
	}
	if adminAssetID == 0 {
		t.Fatalf("expected admin_only.png in admin list, got %+v", adminList.Assets)
	}

	memberProbeAdminAI := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, fmt.Sprintf("/photos/%d/ai", adminAssetID)), "")
	if memberProbeAdminAI.Code != http.StatusNotFound {
		t.Fatalf("expected 404 anti-oracle when member probes admin photo AI, got %d %s", memberProbeAdminAI.Code, memberProbeAdminAI.Body.String())
	}

	// Create second member (member2) granted only SharedAlbum, never member 1's private space.
	member2User, err := f.accounts.CreateUser(f.admin, "bob", "StrongPass!234", "member")
	if err != nil {
		t.Fatal(err)
	}
	if err := f.accounts.SetRootGrant(f.admin, member2User.ID, f.rootA.ID, "SharedAlbum", false); err != nil {
		t.Fatal(err)
	}
	member2Session, err := f.accounts.Login("bob", "StrongPass!234")
	if err != nil {
		t.Fatal(err)
	}

	// Member person clusters, rename, face avatar + ETag/304 negotiation, and cross-member 404 anti-oracle.
	personsResp := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/photos/persons"), "")
	if personsResp.Code != http.StatusOK {
		t.Fatalf("member persons failed: %d %s", personsResp.Code, personsResp.Body.String())
	}
	var pPayload struct {
		Persons []struct {
			ID          int64 `json:"id"`
			CoverFaceID int64 `json:"coverFaceId"`
			PhotoCount  int   `json:"photoCount"`
		} `json:"persons"`
	}
	_ = json.Unmarshal(personsResp.Body.Bytes(), &pPayload)
	if len(pPayload.Persons) != 1 || pPayload.Persons[0].PhotoCount != 2 {
		t.Fatalf("expected 1 person cluster with 2 photos for member, got %+v", pPayload.Persons)
	}
	personID := pPayload.Persons[0].ID
	faceID := pPayload.Persons[0].CoverFaceID

	renameResp := f.call(f.member, http.MethodPatch, rootRoute(f.rootA.ID, fmt.Sprintf("/photos/persons/%d", personID)), `{"name":"小宝"}`)
	if renameResp.Code != http.StatusOK {
		t.Fatalf("rename person failed: %d %s", renameResp.Code, renameResp.Body.String())
	}
	faceResp := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, fmt.Sprintf("/photos/faces/%d/thumbnail", faceID)), "")
	if faceResp.Code != http.StatusOK || faceResp.Header().Get("Content-Type") != "image/jpeg" {
		t.Fatalf("member face avatar failed: %d", faceResp.Code)
	}
	faceETag := faceResp.Header().Get("ETag")
	if faceETag == "" {
		t.Fatalf("expected non-empty ETag on face avatar response")
	}
	face304Req := httptest.NewRequest(http.MethodGet, rootRoute(f.rootA.ID, fmt.Sprintf("/photos/faces/%d/thumbnail", faceID)), nil)
	face304Req.AddCookie(&http.Cookie{Name: sessionCookie, Value: f.member})
	face304Req.Header.Set("If-None-Match", faceETag)
	face304Resp := httptest.NewRecorder()
	f.server.ServeHTTP(face304Resp, face304Req)
	if face304Resp.Code != http.StatusNotModified || face304Resp.Body.Len() != 0 {
		t.Fatalf("expected 304 Not Modified with empty body on matching face ETag, got %d len=%d", face304Resp.Code, face304Resp.Body.Len())
	}
	member2ProbeMember1Face := f.call(member2Session, http.MethodGet, rootRoute(f.rootA.ID, fmt.Sprintf("/photos/faces/%d/thumbnail", faceID)), "")
	if member2ProbeMember1Face.Code != http.StatusNotFound {
		t.Fatalf("expected 404 anti-oracle when member2 requests member1's private face avatar, got %d", member2ProbeMember1Face.Code)
	}

	// Similar photos cleanup + keep-1 guardrail.
	simResp := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/photos/cleanup/similar"), "")
	if simResp.Code != http.StatusOK {
		t.Fatalf("similar cleanup list failed: %d %s", simResp.Code, simResp.Body.String())
	}
	var simPayload struct {
		Groups []similarGroupResponse `json:"groups"`
	}
	_ = json.Unmarshal(simResp.Body.Bytes(), &simPayload)
	if len(simPayload.Groups) != 1 || len(simPayload.Groups[0].Items) != 2 {
		t.Fatalf("expected 1 similar group for member, got %+v", simPayload.Groups)
	}
	keepID := simPayload.Groups[0].RecommendedAssetID
	var wasteID int64
	for _, it := range simPayload.Groups[0].Items {
		if it.AssetID != keepID {
			wasteID = it.AssetID
		}
	}
	badSimTrash := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/photos/cleanup/trash"),
		fmt.Sprintf(`{"keepAssetId":%d,"trashAssetIds":[%d,%d]}`, keepID, keepID, wasteID))
	if badSimTrash.Code != http.StatusBadRequest || !strings.Contains(badSimTrash.Body.String(), "must_keep_one_photo") {
		t.Fatalf("expected must_keep_one_photo guardrail, got %d %s", badSimTrash.Code, badSimTrash.Body.String())
	}
	okSimTrash := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/photos/cleanup/trash"),
		fmt.Sprintf(`{"keepAssetId":%d,"trashAssetIds":[%d]}`, keepID, wasteID))
	if okSimTrash.Code != http.StatusOK {
		t.Fatalf("trash waste photo failed: %d %s", okSimTrash.Code, okSimTrash.Body.String())
	}
	simAfter := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/photos/cleanup/similar"), "")
	if strings.Contains(simAfter.Body.String(), "member_burst_1.png") {
		t.Fatalf("expected trashed burst photo to disappear immediately, got %s", simAfter.Body.String())
	}

	// Full-disk duplicate scanner: member sees ONLY member's 2 duplicate files (never AdminSecret/admin_hidden_copy.bin!).
	dupScan := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/files/duplicates/scan"), `{"minSizeBytes":4096}`)
	if dupScan.Code != http.StatusOK {
		t.Fatalf("duplicate scan failed: %d %s", dupScan.Code, dupScan.Body.String())
	}
	var dupSnap duplicateScanSnapshot
	if err := json.Unmarshal(dupScan.Body.Bytes(), &dupSnap); err != nil || dupSnap.Result == nil {
		t.Fatalf("decode duplicate scan: %+v err=%v", dupSnap, err)
	}
	if len(dupSnap.Result.Groups) != 1 || dupSnap.Result.Groups[0].Count != 2 {
		t.Fatalf("expected 1 group of 2 files for member (no cross-user leak), got %+v", dupSnap.Result)
	}
	itemKeep := dupSnap.Result.Groups[0].Items[0]
	itemTrash := dupSnap.Result.Groups[0].Items[1]

	badDupTrash := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/files/duplicates/trash"),
		fmt.Sprintf(`{"groups":[{"keepPath":%q,"trashItems":[{"path":%q,"size":%d,"identity":%q}]}]}`,
			itemKeep.Path, itemKeep.Path, itemKeep.Size, itemKeep.Identity))
	if badDupTrash.Code != http.StatusBadRequest || !strings.Contains(badDupTrash.Body.String(), "must_keep_one_file") {
		t.Fatalf("expected must_keep_one_file guardrail, got %d %s", badDupTrash.Code, badDupTrash.Body.String())
	}

	okDupTrash := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/files/duplicates/trash"),
		fmt.Sprintf(`{"groups":[{"keepPath":%q,"trashItems":[{"path":%q,"size":%d,"identity":%q}]}]}`,
			itemKeep.Path, itemTrash.Path, itemTrash.Size, itemTrash.Identity))
	if okDupTrash.Code != http.StatusOK {
		t.Fatalf("duplicate trash failed: %d %s", okDupTrash.Code, okDupTrash.Body.String())
	}

	dupAfter := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/files/duplicates"), "")
	var afterSnap duplicateScanSnapshot
	_ = json.Unmarshal(dupAfter.Body.Bytes(), &afterSnap)
	if afterSnap.Result == nil || len(afterSnap.Result.Groups) != 0 {
		t.Fatalf("expected 0 duplicate groups after trashing copy, got %+v", afterSnap)
	}

	// Verify async duplicate scan + polling + dynamic ACL recalculation on grant downgrade/revocation!
	sharedDupA := filepath.Join(f.pathA, "SharedAlbum", "shared_dup_a.bin")
	sharedDupB := filepath.Join(f.pathA, "SharedAlbum", "shared_dup_b.bin")
	sharedPayload := bytes.Repeat([]byte("Shared-Dup-Data-"), 600)
	if err := os.WriteFile(sharedDupA, sharedPayload, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sharedDupB, sharedPayload, 0600); err != nil {
		t.Fatal(err)
	}
	asyncScan := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/files/duplicates/scan"), `{"minSizeBytes":4096,"async":true}`)
	if asyncScan.Code != http.StatusAccepted && asyncScan.Code != http.StatusOK {
		t.Fatalf("async duplicate scan failed: %d %s", asyncScan.Code, asyncScan.Body.String())
	}
	var polledSnap duplicateScanSnapshot
	pollDeadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(pollDeadline) {
		pollResp := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/files/duplicates"), "")
		_ = json.Unmarshal(pollResp.Body.Bytes(), &polledSnap)
		if !polledSnap.Running && polledSnap.Result != nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if polledSnap.Running || polledSnap.Result == nil || len(polledSnap.Result.Groups) != 1 {
		t.Fatalf("expected async duplicate scan to finish with 1 shared group, got %+v", polledSnap)
	}
	if !polledSnap.Result.Groups[0].Items[0].CanTrash {
		t.Fatalf("expected CanTrash=true while member has RW grant on SharedAlbum")
	}

	// Downgrade SharedAlbum grant to read-only: cached GET /files/duplicates must dynamically recompute CanTrash=false!
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootA.ID, "SharedAlbum", false); err != nil {
		t.Fatal(err)
	}
	roSnapResp := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/files/duplicates"), "")
	var roSnap duplicateScanSnapshot
	_ = json.Unmarshal(roSnapResp.Body.Bytes(), &roSnap)
	if roSnap.Result == nil || len(roSnap.Result.Groups) != 1 || roSnap.Result.Groups[0].Items[0].CanTrash {
		t.Fatalf("expected CanTrash=false immediately after write grant downgrade, got %+v", roSnap.Result)
	}

	// Revoke SharedAlbum grant completely: cached GET /files/duplicates must hide unauthorized files immediately!
	if err := f.accounts.RemoveRootGrant(f.admin, f.memberID, f.rootA.ID, "SharedAlbum"); err != nil {
		t.Fatal(err)
	}
	revokedResp := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/files/duplicates"), "")
	var revokedSnap duplicateScanSnapshot
	_ = json.Unmarshal(revokedResp.Body.Bytes(), &revokedSnap)
	if revokedSnap.Result == nil || len(revokedSnap.Result.Groups) != 0 {
		t.Fatalf("expected 0 visible duplicate groups after SharedAlbum grant revocation, got %+v", revokedSnap.Result)
	}

	// Cancel endpoint returns 200 OK cleanly when idle.
	cancelResp := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/files/duplicates/cancel"), `{}`)
	if cancelResp.Code != http.StatusOK {
		t.Fatalf("expected 200 on duplicates/cancel, got %d %s", cancelResp.Code, cancelResp.Body.String())
	}
}
