package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

func TestSwitchUserStorageRootTaskLifecycle(t *testing.T) {
	base := t.TempDir()
	volume := filepath.Join(base, "volume")
	private := filepath.Join(base, "private")
	diskAPath := filepath.Join(volume, "diskA")
	diskBPath := filepath.Join(volume, "diskB")
	for _, dir := range []string{volume, private, diskAPath, diskBPath} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(private, rootRoutingProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	diskA, err := registry.Add(context.Background(), "Primary SSD", diskAPath)
	if err != nil {
		t.Fatal(err)
	}
	diskB, err := registry.Add(context.Background(), "External NVMe", diskBPath)
	if err != nil {
		t.Fatal(err)
	}
	accounts, err := auth.Open(filepath.Join(private, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "owner-storage-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "owner-storage-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(admin, "alice", "alice-storage-password-2026", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	handler := NewWithRoots("", accounts, nil, nil, nil, nil, registry,
		func(_ context.Context, _ roots.Root, lease *roots.Lease) (*RootServices, error) {
			manager, err := files.NewPinnedManager(lease.Root)
			if err != nil {
				return nil, err
			}
			return &RootServices{Files: manager}, nil
		})
	defer handler.Close()

	uid := strconv.FormatInt(member.ID, 10)
	genAStr := strconv.FormatUint(diskA.Generation, 10)
	genBStr := strconv.FormatUint(diskB.Generation, 10)

	call := func(method, path, body, gen string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		r.AddCookie(&http.Cookie{Name: sessionCookie, Value: admin})
		r.Header.Set("X-LightIsle-Request", "1")
		if gen != "" {
			r.Header.Set(rootGenerationHeader, gen)
		}
		if body != "" {
			r.Header.Set("Content-Type", "application/json")
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}

	taskPath := "/api/v2/users/" + uid + "/storage/switch-root"
	awaitTask := func(first *httptest.ResponseRecorder, phase string) SwitchUserStorageResponse {
		t.Helper()
		if first.Code != http.StatusOK {
			t.Fatalf("task request failed: %d %s", first.Code, first.Body.String())
		}
		var result SwitchUserStorageResponse
		if err := json.Unmarshal(first.Body.Bytes(), &result); err != nil || result.TaskID == "" {
			t.Fatalf("missing task ID: %v %s", err, first.Body.String())
		}
		deadline := time.Now().Add(5 * time.Second)
		for result.Phase != phase {
			if (result.Error != "" && result.Phase != phase) || time.Now().After(deadline) {
				t.Fatalf("expected phase %q, got %q (%s)", phase, result.Phase, result.Error)
			}
			time.Sleep(10 * time.Millisecond)
			status := call(http.MethodPost, taskPath, `{"phase":"status","taskID":"`+result.TaskID+`"}`, "")
			if status.Code != http.StatusOK {
				t.Fatalf("status request failed: %d %s", status.Code, status.Body.String())
			}
			if err := json.Unmarshal(status.Body.Bytes(), &result); err != nil {
				t.Fatal(err)
			}
		}
		return result
	}

	// 1. Allocate admin's own storage space on diskA (unlimited quota).
	adminAlloc := call(http.MethodPost, "/api/v2/roots/"+diskA.ID+"/users/1/storage",
		`{"categories":["files","photos","videos"]}`, genAStr)
	if adminAlloc.Code != http.StatusOK {
		t.Fatalf("admin storage allocation failed: %d %s", adminAlloc.Code, adminAlloc.Body.String())
	}
	var adminPolicy auth.StoragePolicy
	if err := json.Unmarshal(adminAlloc.Body.Bytes(), &adminPolicy); err != nil || !adminPolicy.Unlimited || adminPolicy.Role != auth.RoleAdmin || len(adminPolicy.Locations) != 3 {
		t.Fatalf("expected admin unlimited policy with 3 locations: %+v %v", adminPolicy, err)
	}

	// 2. Allocate member's files & photos on diskA.
	quota50G := int64(50 << 30)
	memberAlloc := call(http.MethodPost, "/api/v2/roots/"+diskA.ID+"/users/"+uid+"/storage",
		`{"quotaBytes":`+strconv.FormatInt(quota50G, 10)+`,"categories":["files","photos","videos"],"subdirectories":["files/docs"]}`, genAStr)
	if memberAlloc.Code != http.StatusOK {
		t.Fatalf("member storage allocation failed: %d %s", memberAlloc.Code, memberAlloc.Body.String())
	}

	// Write sample files in member's files and photos on diskA.
	docPath := filepath.Join(diskAPath, "Users", "u"+uid, "files", "docs", "report.txt")
	if err := os.WriteFile(docPath, []byte("hello-copy-mode-2026"), 0600); err != nil {
		t.Fatal(err)
	}
	photoDir := filepath.Join(diskAPath, "Users", "u"+uid, "photos", "2026")
	if err := os.MkdirAll(photoDir, 0700); err != nil {
		t.Fatal(err)
	}
	photoPath := filepath.Join(photoDir, "trip.jpg")
	if err := os.WriteFile(photoPath, []byte("jpeg-migrate-payload-2026"), 0600); err != nil {
		t.Fatal(err)
	}

	// 3. Switch "files" from diskA to diskB in "copy" mode (must keep source file on diskA).
	copySwitch := call(http.MethodPost, "/api/v2/users/"+uid+"/storage/switch-root",
		`{"categories":["files"],"sourceRootID":"`+diskA.ID+`","sourceGeneration":`+genAStr+`,"targetRootID":"`+diskB.ID+`","targetGeneration":`+genBStr+`,"mode":"copy"}`, "")
	copyResp := awaitTask(copySwitch, "completed")
	if copyResp.CopiedFiles != 1 {
		t.Fatalf("unexpected copy response: %+v", copyResp)
	}
	// Both diskA and diskB must have report.txt in "copy" mode!
	if data, err := os.ReadFile(filepath.Join(diskBPath, "Users", "u"+uid, "files", "docs", "report.txt")); err != nil || string(data) != "hello-copy-mode-2026" {
		t.Fatalf("target file missing or mismatched after copy switch: %v %q", err, string(data))
	}
	if data, err := os.ReadFile(docPath); err != nil || string(data) != "hello-copy-mode-2026" {
		t.Fatalf("source file was deleted in copy mode: %v", err)
	}

	// 4. Switch "photos" from diskA to diskB in two-phase "migrate" mode:
	// Phase 1: copy_and_verify (copies and verifies SHA-256, keeps source intact until confirmed).
	migrateStep1 := call(http.MethodPost, "/api/v2/users/"+uid+"/storage/switch-root",
		`{"categories":["photos"],"sourceRootID":"`+diskA.ID+`","sourceGeneration":`+genAStr+`,"targetRootID":"`+diskB.ID+`","targetGeneration":`+genBStr+`,"mode":"migrate","phase":"copy_and_verify"}`, "")
	step1Resp := awaitTask(migrateStep1, "verified")
	if !step1Resp.ReadyToCleanup || step1Resp.VerifiedFiles != 1 {
		t.Fatalf("unexpected migrate step 1 response: %+v", step1Resp)
	}
	if _, err := os.Stat(filepath.Join(diskBPath, "Users", "u"+uid, "photos")); !os.IsNotExist(err) {
		t.Fatalf("unconfirmed destination must not be published: %v", err)
	}
	if result := call(http.MethodPost, taskPath, `{"phase":"confirm_cleanup"}`, ""); result.Code != http.StatusBadRequest {
		t.Fatalf("unbound confirmation was accepted: %d", result.Code)
	}
	if _, err := os.Stat(photoPath); err != nil {
		t.Fatalf("source photo should still exist before confirm_cleanup: %v", err)
	}

	// The original remains recoverable through the exact trash receipt.
	confirm := `{"phase":"confirm_cleanup","taskID":"` + step1Resp.TaskID + `"}`
	photoParent := filepath.Dir(filepath.Dir(filepath.Dir(photoPath)))
	if err := os.Chmod(photoParent, 0500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(photoParent, 0700) })
	pending := awaitTask(call(http.MethodPost, taskPath, confirm, ""), "source_pending")
	if pending.DeletedSourceFiles != 0 {
		t.Fatalf("failed cleanup claimed it moved files: %+v", pending)
	}
	if _, err := os.Stat(photoPath); err != nil {
		t.Fatalf("source missing after failed cleanup: %v", err)
	}
	if err := os.Chmod(photoParent, 0700); err != nil {
		t.Fatal(err)
	}
	recoverSource := `{"phase":"recover_source","taskID":"` + step1Resp.TaskID + `"}`
	step2Resp := awaitTask(call(http.MethodPost, taskPath, recoverSource, ""), "completed")
	if step2Resp.DeletedSourceFiles != 1 || step2Resp.TrashIDs["photos"] == "" {
		t.Fatalf("unexpected migrate step 2 response: %+v", step2Resp)
	}
	if duplicate := awaitTask(call(http.MethodPost, taskPath, confirm, ""), "completed"); duplicate.TaskID != step2Resp.TaskID {
		t.Fatal("duplicate confirmation started a new task")
	}
	lease, err := handler.AcquireRootServices(context.Background(), diskA.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	if entry, err := lease.Services.Files.TrashInfo(step2Resp.TrashIDs["photos"]); err != nil || entry.OriginalPath != "Users/u"+uid+"/photos" {
		t.Fatalf("source must be recoverable by exact receipt: %+v %v", entry, err)
	}
	if data, err := os.ReadFile(filepath.Join(diskBPath, "Users", "u"+uid, "photos", "2026", "trip.jpg")); err != nil || string(data) != "jpeg-migrate-payload-2026" {
		t.Fatalf("target photo missing after migrate completion: %v", err)
	}
	if _, err := os.Stat(photoPath); !os.IsNotExist(err) {
		t.Fatalf("expected source photo removed after confirm_cleanup, got: %v", err)
	}

	// An older root-wide grant must not give the member access to detached
	// data, including case aliases on default macOS volumes.
	if err := accounts.SetRootGrant(admin, member.ID, diskA.ID, ".", true); err != nil {
		t.Fatal(err)
	}
	memberSession, err := accounts.Login("alice", "alice-storage-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	videoPath := filepath.Join(diskAPath, "Users", "u"+uid, "videos", "original.mp4")
	if err := os.WriteFile(videoPath, []byte("original video"), 0600); err != nil {
		t.Fatal(err)
	}
	offlineDisk := diskAPath + "-offline"
	if err := os.Rename(diskAPath, offlineDisk); err != nil {
		t.Fatal(err)
	}
	emptySwitch := call(http.MethodPost, taskPath,
		`{"categories":["videos"],"sourceRootID":"`+diskA.ID+`","sourceGeneration":`+genAStr+`,"targetRootID":"`+diskB.ID+`","targetGeneration":`+genBStr+`,"mode":"empty"}`, "")
	awaitTask(emptySwitch, "completed")
	if err := os.Rename(offlineDisk, diskAPath); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(videoPath); err != nil {
		t.Fatalf("empty switch altered the source: %v", err)
	}
	relative := "users/U" + uid + "/Videos/original.mp4"
	if accounts.CanAccessRoot(memberSession, diskA.ID, relative, false, false) ||
		accounts.UserCanReadRoot(member.ID, diskA.ID, relative) {
		t.Fatal("broad grant exposed detached data")
	}
	if roots, err := accounts.SearchRootsRoot(memberSession, diskA.ID, "."); err != nil || len(roots) != 0 {
		t.Fatalf("search scopes include detached data: %v %v", roots, err)
	}
	newVideos := filepath.Join(diskBPath, "Users", "u"+uid, "videos")
	if entries, err := os.ReadDir(newVideos); err != nil || len(entries) != 0 {
		t.Fatalf("expected empty target: %v %v", entries, err)
	}
	if err := os.WriteFile(filepath.Join(newVideos, "move.mp4"), []byte("direct move"), 0600); err != nil {
		t.Fatal(err)
	}
	moveSwitch := call(http.MethodPost, taskPath,
		`{"categories":["videos"],"sourceRootID":"`+diskB.ID+`","sourceGeneration":`+genBStr+`,"targetRootID":"`+diskA.ID+`","targetGeneration":`+genAStr+`,"mode":"move"}`, "")
	awaitTask(moveSwitch, "failed")
	if data, err := os.ReadFile(videoPath); err != nil || string(data) != "original video" {
		t.Fatalf("target conflict altered the original: %v %s", err, data)
	}
	if err := os.Remove(videoPath); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Dir(videoPath)); err != nil {
		t.Fatal(err)
	}
	moveSwitch = call(http.MethodPost, taskPath,
		`{"categories":["videos"],"sourceRootID":"`+diskB.ID+`","sourceGeneration":`+genBStr+`,"targetRootID":"`+diskA.ID+`","targetGeneration":`+genAStr+`,"mode":"move"}`, "")
	if result := awaitTask(moveSwitch, "completed"); result.DeletedSourceFiles != 1 || result.TrashIDs["videos"] == "" {
		t.Fatalf("move must report the exact recoverable source item: %+v", result)
	}
}
