package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
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
		if method == http.MethodPost && strings.Contains(path, "/storage/switch-root") && body != "" {
			var payload map[string]any
			if json.Unmarshal([]byte(body), &payload) == nil && payload["phase"] != "status" {
				payload["confirmationPassword"] = "owner-storage-password-2026"
				encoded, err := json.Marshal(payload)
				if err != nil {
					t.Fatal(err)
				}
				body = string(encoded)
			}
		}
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
	if saved, err := accounts.LoadStorageSwitchTask(member.ID, copyResp.TaskID); err != nil ||
		strings.Contains(string(saved.Request), "owner-storage-password-2026") {
		t.Fatalf("admin confirmation secret leaked into a persisted migration task: %v", err)
	}
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

	// A received, database-registered folder album creates a symlink inside
	// the member's photos root. It must not prevent a verified disk switch,
	// and its old physical link must be removed after the sharing row is revoked.
	oldAlbumLink := filepath.Join(diskAPath, "Users", "u"+uid, "photos", "Family")
	if runtime.GOOS == "darwin" {
		ownerAlbum := filepath.Join(diskAPath, "Users", "u1", "photos", "Family")
		if err := os.MkdirAll(ownerAlbum, 0700); err != nil {
			t.Fatal(err)
		}
		if _, err := accounts.ShareFolderAlbum(admin, diskA.ID, diskA.Generation, "Family", "Family", member.ID, false); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink("../../u1/photos/Family", oldAlbumLink); err != nil {
			t.Fatal(err)
		}
		if _, err := accounts.UnshareFolderAlbumWithCleanup(admin, diskA.ID, diskA.Generation, 1, "Family", member.ID,
			func(auth.SharedFolderAlbum) error { return errors.New("simulated filesystem failure") }); err == nil {
			t.Fatal("album share revocation discarded the database grant despite failed physical cleanup")
		}
		shares, err := accounts.ListOwnedFolderAlbumShares(admin, diskA.ID, diskA.Generation)
		if err != nil || len(shares["Family"]) != 1 {
			t.Fatalf("failed cleanup did not leave an actionable album share for retry: %v %+v", err, shares)
		}
	}

	// 4. Switch "photos" from diskA to diskB in two-phase "migrate" mode:
	// Phase 1: copy_and_verify (copies and verifies SHA-256, keeps source intact until confirmed).
	migrateStep1 := call(http.MethodPost, "/api/v2/users/"+uid+"/storage/switch-root",
		`{"categories":["photos"],"sourceRootID":"`+diskA.ID+`","sourceGeneration":`+genAStr+`,"targetRootID":"`+diskB.ID+`","targetGeneration":`+genBStr+`,"mode":"migrate","phase":"copy_and_verify"}`, "")
	step1Resp := awaitTask(migrateStep1, "verified")
	if !step1Resp.ReadyToCleanup || step1Resp.VerifiedFiles != 1 || step1Resp.TotalFiles != 1 || step1Resp.TotalBytes != int64(len("jpeg-migrate-payload-2026")) {
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
	if runtime.GOOS == "darwin" {
		if _, err := os.Lstat(oldAlbumLink); !os.IsNotExist(err) {
			t.Fatalf("revoked shared album symlink must be unlinked: %v", err)
		}
		if _, err := os.Lstat(filepath.Join(diskBPath, "Users", "u"+uid, "photos", "Family")); !os.IsNotExist(err) {
			t.Fatalf("old shared album link must not be copied to new root: %v", err)
		}
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

	// Interrupt a two-category task after its first exclusive rename. The
	// older progress format does not contain the client-facing resume flag.
	adminTaskPath := "/api/v2/users/1/storage/switch-root"
	const filesPrefix = "Users/u1/files"
	const photosPrefix = "Users/u1/photos"
	sourceFile := filepath.Join(diskAPath, filesPrefix, "verified.txt")
	targetFile := filepath.Join(diskBPath, filesPrefix, "verified.txt")
	if err := os.WriteFile(sourceFile, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	request := `{"categories":["files","photos"],"sourceRootID":"` + diskA.ID + `","sourceGeneration":` + genAStr +
		`,"targetRootID":"` + diskB.ID + `","targetGeneration":` + genBStr + `,"mode":"migrate"}`
	first := call(http.MethodPost, adminTaskPath, request, "")
	var recoverable SwitchUserStorageResponse
	if err := json.Unmarshal(first.Body.Bytes(), &recoverable); err != nil || first.Code != http.StatusOK || recoverable.TaskID == "" {
		t.Fatalf("cannot prepare interrupted switch: %v %s", err, first.Body.String())
	}
	waitForIdle := func() {
		deadline := time.Now().Add(5 * time.Second)
		for {
			handler.switchMu.Lock()
			idle := handler.switchTaskID == ""
			handler.switchMu.Unlock()
			if idle {
				return
			}
			if time.Now().After(deadline) {
				t.Fatal("storage switch did not settle")
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
	waitForIdle()
	record, err := accounts.LoadStorageSwitchTask(1, recoverable.TaskID)
	if err != nil {
		t.Fatal(err)
	}
	var interrupted storageSwitchProgress
	if err := json.Unmarshal(record.Progress, &interrupted); err != nil || interrupted.Phase != "verified" {
		t.Fatalf("invalid stage: %v %+v", err, interrupted)
	}
	target, err := handler.AcquireRootServices(context.Background(), diskB.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	dst := target.Services.Files.(*files.Manager)
	interrupted.Phase, interrupted.Publishing = "committing", true
	interrupted.TrashIDs = map[string]string{"files": strings.Repeat("a", 32), "photos": strings.Repeat("b", 32)}
	interrupted.Published = make(map[string]files.StorageSwitchTree)
	for category, prefix := range map[string]string{"files": filesPrefix, "photos": photosPrefix} {
		tree, err := dst.StagedStorageSwitchTree(context.Background(), interrupted.TaskID, category)
		if err != nil {
			t.Fatal(err)
		}
		interrupted.Published[prefix] = tree
	}
	if err := handler.saveSwitch(interrupted); err != nil {
		t.Fatal(err)
	}
	if err := dst.PublishStorageSwitch(interrupted.TaskID, filesPrefix); err != nil {
		t.Fatal(err)
	}
	checkTask := func(phase string) SwitchUserStorageResponse {
		t.Helper()
		resp := call(http.MethodPost, adminTaskPath, `{"phase":"`+phase+`","taskID":"`+interrupted.TaskID+`"}`, "")
		var got SwitchUserStorageResponse
		if err := json.Unmarshal(resp.Body.Bytes(), &got); err != nil || resp.Code != http.StatusOK {
			t.Fatalf("phase %s: %v %s", phase, err, resp.Body.String())
		}
		return got
	}
	if got := checkTask("status"); got.Phase != "interrupted" || !got.CanResume {
		t.Fatalf("interrupted task cannot resume: %+v", got)
	}
	if err := os.WriteFile(targetFile, []byte("modified"), 0600); err != nil {
		t.Fatal(err)
	}
	checkTask("resume_publish")
	waitForIdle()
	if got := checkTask("status"); got.Phase != "interrupted" || got.ReviewPath != filesPrefix || !got.CanResume {
		t.Fatalf("changed target must remain pending: %+v", got)
	}
	if _, err := os.Stat(sourceFile); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(diskBPath, photosPrefix)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("an unverified task published the remaining category: %v", err)
	}
	if err := os.WriteFile(targetFile, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	checkTask("resume_publish")
	waitForIdle()
	if got := checkTask("resume_publish"); got.Phase != "completed" || got.CanResume || got.DeletedSourceFiles != 1 {
		t.Fatalf("resumed task did not complete exactly once: %+v", got)
	}
}

func TestStorageSwitchRequiresIndependentAdministratorConfirmation(t *testing.T) {
	f := newRootRoutingFixture(t)
	endpoint := "/api/v2/users/" + strconv.FormatInt(f.memberID, 10) + "/storage/switch-root"
	request := func(body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, endpoint, strings.NewReader(body))
		r.Header.Set("X-LightIsle-Request", "1")
		r.Header.Set("Content-Type", "application/json")
		r.AddCookie(&http.Cookie{Name: sessionCookie, Value: f.admin})
		w := httptest.NewRecorder()
		f.server.ServeHTTP(w, r)
		return w
	}
	for _, body := range []string{
		`{"phase":"cancel","taskID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`,
		`{"phase":"cancel","taskID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","confirmationPassword":"wrong-password-2026"}`,
	} {
		if got := request(body); got.Code != http.StatusForbidden {
			t.Fatalf("mutation with only session/incorrect password accepted: %d %s", got.Code, got.Body)
		}
	}
	if got := request(`{"phase":"cancel","taskID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","confirmationPassword":"long-initial-password"}`); got.Code != http.StatusNotFound {
		t.Fatalf("confirmed admin should pass step-up and reach task lookup: %d %s", got.Code, got.Body)
	}

	uid := strconv.FormatInt(f.memberID, 10)
	alloc := f.call(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/users/"+uid+"/storage"), `{"categories":["files"]}`)
	if alloc.Code != http.StatusOK {
		t.Fatalf("allocate storage: %d %s", alloc.Code, alloc.Body)
	}
	startBody := `{"categories":["files"],"sourceRootID":"` + f.rootA.ID + `","sourceGeneration":` + strconv.FormatUint(f.rootA.Generation, 10) +
		`,"targetRootID":"` + f.rootB.ID + `","targetGeneration":` + strconv.FormatUint(f.rootB.Generation, 10) +
		`,"mode":"migrate","phase":"copy_and_verify","confirmationPassword":"long-initial-password"}`
	startedRaw := request(startBody)
	var started SwitchUserStorageResponse
	if err := json.Unmarshal(startedRaw.Body.Bytes(), &started); err != nil || startedRaw.Code != http.StatusOK || started.ConfirmationToken == "" {
		t.Fatalf("expected step-up confirmation token from password-verified start: %d %s %v", startedRaw.Code, startedRaw.Body, err)
	}
	for deadline := time.Now().Add(5 * time.Second); started.Phase != "verified"; {
		if time.Now().After(deadline) {
			t.Fatalf("task did not reach verified: %+v", started)
		}
		time.Sleep(10 * time.Millisecond)
		pollRaw := request(`{"phase":"status","taskID":"` + started.TaskID + `"}`)
		_ = json.Unmarshal(pollRaw.Body.Bytes(), &started)
	}
	if wrongTask := request(`{"phase":"confirm_cleanup","taskID":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","confirmationToken":"` + started.ConfirmationToken + `"}`); wrongTask.Code != http.StatusForbidden {
		t.Fatalf("token bound to another taskID was accepted: %d %s", wrongTask.Code, wrongTask.Body)
	}
	confirmRaw := request(`{"phase":"confirm_cleanup","taskID":"` + started.TaskID + `","confirmationToken":"` + started.ConfirmationToken + `"}`)
	if confirmRaw.Code != http.StatusOK {
		t.Fatalf("expected step-up confirmation token to authorize confirm_cleanup without second password prompt: %d %s", confirmRaw.Code, confirmRaw.Body)
	}
}

func TestStorageSwitchCopiesOnlyVerifiedOwnersMediaRecords(t *testing.T) {
	f := newRootRoutingFixture(t)
	uid := strconv.FormatInt(f.memberID, 10)
	home := "Users/u" + uid
	photos, videos := home+"/photos", home+"/videos"
	allocation := f.call(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/users/"+uid+"/storage"), `{"categories":["photos","videos"]}`)
	if allocation.Code != http.StatusOK {
		t.Fatalf("allocate storage: %d %s", allocation.Code, allocation.Body)
	}
	for _, file := range []string{photos + "/trip.jpg", videos + "/film.mp4"} {
		if err := os.WriteFile(filepath.Join(f.pathA, file), []byte("fixture"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	startRootScans(t, f, f.rootA.ID)
	source := f.services[f.rootA.ID]
	assets, _, err := source.Gallery.ListScoped(0, 10, 0, false, []string{photos})
	if err != nil || len(assets) != 1 {
		t.Fatalf("source assets: %+v %v", assets, err)
	}
	films, _, err := source.Cinema.ListScoped(f.memberID, "", "", 10, 0, []string{videos})
	if err != nil || len(films) != 1 {
		t.Fatalf("source films: %+v %v", films, err)
	}
	album, err := source.Gallery.CreatePrivateAlbum(f.memberID, "旅行")
	if err != nil {
		t.Fatal(err)
	}
	if err := source.Gallery.AddToPrivateAlbum(f.memberID, album.ID, assets[0].ID); err != nil {
		t.Fatal(err)
	}
	for _, owner := range []int64{1, f.memberID} {
		if err := source.Gallery.PersonalFavorite(owner, assets[0].ID, true); err != nil {
			t.Fatal(err)
		}
		if err := source.Cinema.SaveProgress(owner, films[0].ID, float64(owner)+10, 120, false); err != nil {
			t.Fatal(err)
		}
	}
	endpoint := "/api/v2/users/" + uid + "/storage/switch-root"
	req := SwitchUserStorageRequest{
		Categories: []string{"photos", "videos"}, Mode: "copy",
		SourceRootID: f.rootA.ID, SourceGeneration: f.rootA.Generation,
		TargetRootID: f.rootB.ID, TargetGeneration: f.rootB.Generation,
	}
	read := func(req SwitchUserStorageRequest) SwitchUserStorageResponse {
		t.Helper()
		if req.Phase != "status" {
			req.ConfirmationPassword = "long-initial-password"
		}
		body, _ := json.Marshal(req)
		out := f.call(f.admin, http.MethodPost, endpoint, string(body))
		var result SwitchUserStorageResponse
		if err := json.Unmarshal(out.Body.Bytes(), &result); err != nil || out.Code != http.StatusOK {
			t.Fatalf("storage switch: %d %s %v", out.Code, out.Body, err)
		}
		return result
	}
	result := read(req)
	for deadline := time.Now().Add(5 * time.Second); result.Phase != "completed"; {
		if result.Error != "" || time.Now().After(deadline) {
			t.Fatalf("media switch did not complete: %+v", result)
		}
		time.Sleep(10 * time.Millisecond)
		result = read(SwitchUserStorageRequest{TaskID: result.TaskID, Phase: "status"})
	}
	target := f.services[f.rootB.ID]
	albums, err := target.Gallery.PrivateAlbumsScoped(f.memberID, []string{photos})
	if err != nil || len(albums) != 1 || albums[0].Count != 1 || albums[0].Name != "旅行" {
		t.Fatalf("verified private album not restored: %+v %v", albums, err)
	}
	for _, owner := range []int64{1, f.memberID} {
		wantCount, wantProgress := 0, float64(0)
		if owner == f.memberID {
			wantCount, wantProgress = 1, float64(owner)+10
		}
		favs, _, err := target.Gallery.ListScopedForUser(owner, 0, 10, 0, false, true, []string{photos})
		if err != nil || len(favs) != wantCount {
			t.Fatalf("favorite scope for owner %d: %+v %v", owner, favs, err)
		}
		got, _, err := target.Cinema.ListScoped(owner, "", "", 10, 0, []string{videos})
		if err != nil || len(got) != 1 || got[0].Position != wantProgress {
			t.Fatalf("progress scope for owner %d: %+v %v", owner, got, err)
		}
	}
}

func TestStorageSwitchIdempotentVerifiedAndEmptyTargetRecovery(t *testing.T) {
	f := newRootRoutingFixture(t)
	uid := strconv.FormatInt(f.memberID, 10)
	filesDir := "Users/u" + uid + "/files"
	alloc := f.call(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/users/"+uid+"/storage"), `{"categories":["files"]}`)
	if alloc.Code != http.StatusOK {
		t.Fatalf("allocate storage: %d %s", alloc.Code, alloc.Body)
	}
	if err := os.WriteFile(filepath.Join(f.pathA, filesDir, "doc.txt"), []byte("payload"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.pathA, filesDir, ".DS_Store"), []byte("finder"), 0600); err != nil {
		t.Fatal(err)
	}
	// Pre-create an empty category directory on target root B to simulate an earlier blank folder.
	if err := os.MkdirAll(filepath.Join(f.pathB, filesDir), 0700); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	firstReq := SwitchUserStorageRequest{
		TaskID:           "11111111111111111111111111111111",
		Categories:       []string{"files"},
		SourceRootID:     f.rootA.ID,
		SourceGeneration: f.rootA.Generation,
		TargetRootID:     f.rootB.ID,
		TargetGeneration: f.rootB.Generation,
		Mode:             "migrate",
		Phase:            "copy_and_verify",
	}
	resp, err := f.server.ExecuteSwitchUserStorage(ctx, "", true, f.memberID, firstReq)
	if err != nil {
		t.Fatalf("start migrate switch: %v", err)
	}
	for deadline := time.Now().Add(5 * time.Second); resp.Phase != "verified"; {
		if resp.Error != "" || time.Now().After(deadline) {
			t.Fatalf("did not reach verified: %+v", resp)
		}
		time.Sleep(10 * time.Millisecond)
		resp, err = f.server.ExecuteSwitchUserStorage(ctx, "", true, f.memberID, SwitchUserStorageRequest{
			TaskID: resp.TaskID,
			Phase:  "status",
		})
		if err != nil {
			t.Fatalf("poll status: %v", err)
		}
	}

	// Re-submitting the same migrate request with a fresh client taskID must return the existing verified task instead of ErrRootBusy.
	retryReq := firstReq
	retryReq.TaskID = "22222222222222222222222222222222"
	retryResp, err := f.server.ExecuteSwitchUserStorage(ctx, "", true, f.memberID, retryReq)
	if err != nil || retryResp.TaskID != firstReq.TaskID || retryResp.Phase != "verified" {
		t.Fatalf("expected idempotent verified task response, got: %+v err=%v", retryResp, err)
	}

	// Switching mode to "copy" with a new client taskID while unconfirmed in "verified" must clean up the old stage and complete the new task.
	copyReq := firstReq
	copyReq.TaskID = "33333333333333333333333333333333"
	copyReq.Mode = "copy"
	copyResp, err := f.server.ExecuteSwitchUserStorage(ctx, "", true, f.memberID, copyReq)
	if err != nil {
		t.Fatalf("start replacement copy switch: %v", err)
	}
	for deadline := time.Now().Add(5 * time.Second); copyResp.Phase != "completed"; {
		if copyResp.Error != "" || time.Now().After(deadline) {
			t.Fatalf("replacement copy switch did not complete: %+v", copyResp)
		}
		time.Sleep(10 * time.Millisecond)
		copyResp, err = f.server.ExecuteSwitchUserStorage(ctx, "", true, f.memberID, SwitchUserStorageRequest{
			TaskID: copyResp.TaskID,
			Phase:  "status",
		})
		if err != nil {
			t.Fatalf("poll replacement status: %v", err)
		}
	}
	if data, err := os.ReadFile(filepath.Join(f.pathB, filesDir, "doc.txt")); err != nil || string(data) != "payload" {
		t.Fatalf("expected target file after copy switch over empty target folder: %v %q", err, string(data))
	}
}

func TestStorageSwitchExFATTargetAndResumeRecovery(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("ExFAT hdiutil test requires darwin")
	}
	f := newRootRoutingFixture(t)
	dmg := filepath.Join(t.TempDir(), "exfat.dmg")
	mnt := filepath.Join(f.volume, "exfat-mnt")
	if err := os.MkdirAll(mnt, 0700); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("hdiutil", "create", "-size", "32m", "-fs", "ExFAT", "-volname", "LIExFAT", dmg).CombinedOutput(); err != nil {
		t.Skipf("hdiutil create unavailable: %v (%s)", err, string(out))
	}
	if out, err := exec.Command("hdiutil", "attach", dmg, "-mountpoint", mnt, "-nobrowse", "-owners", "off").CombinedOutput(); err != nil {
		t.Skipf("hdiutil attach unavailable: %v (%s)", err, string(out))
	}
	t.Cleanup(func() {
		_ = exec.Command("hdiutil", "detach", mnt, "-force").Run()
	})

	exfatShare := filepath.Join(mnt, "LightIsle")
	if err := os.MkdirAll(exfatShare, 0700); err != nil {
		t.Fatal(err)
	}
	exfatRoot, err := f.registry.Add(context.Background(), "ExFAT External", exfatShare)
	if err != nil {
		t.Fatalf("add ExFAT root: %v", err)
	}

	uid := strconv.FormatInt(f.memberID, 10)
	filesDir := "Users/u" + uid + "/files"
	photosDir := "Users/u" + uid + "/photos"
	alloc := f.call(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/users/"+uid+"/storage"), `{"categories":["files","photos"]}`)
	if alloc.Code != http.StatusOK {
		t.Fatalf("allocate storage: %d %s", alloc.Code, alloc.Body)
	}
	if err := os.WriteFile(filepath.Join(f.pathA, filesDir, "doc.txt"), []byte("exfat-payload"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.pathA, filesDir, "empty.txt"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	// Pre-create an empty photos directory on the ExFAT target to verify resume_publish handles pre-existing empty dirs.
	if err := os.MkdirAll(filepath.Join(exfatShare, photosDir), 0700); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	req := SwitchUserStorageRequest{
		TaskID:           "44444444444444444444444444444444",
		Categories:       []string{"files", "photos"},
		SourceRootID:     f.rootA.ID,
		SourceGeneration: f.rootA.Generation,
		TargetRootID:     exfatRoot.ID,
		TargetGeneration: exfatRoot.Generation,
		Mode:             "migrate",
		Phase:            "copy_and_verify",
	}
	resp, err := f.server.ExecuteSwitchUserStorage(ctx, "", true, f.memberID, req)
	if err != nil {
		t.Fatalf("start ExFAT migrate switch: %v", err)
	}
	for deadline := time.Now().Add(8 * time.Second); resp.Phase != "verified"; {
		if resp.Error != "" || time.Now().After(deadline) {
			t.Fatalf("did not reach verified on ExFAT: %+v", resp)
		}
		time.Sleep(15 * time.Millisecond)
		resp, err = f.server.ExecuteSwitchUserStorage(ctx, "", true, f.memberID, SwitchUserStorageRequest{
			TaskID: resp.TaskID,
			Phase:  "status",
		})
		if err != nil {
			t.Fatalf("poll ExFAT status: %v", err)
		}
	}

	// Simulate an interrupted task that failed right before moving any staged category out of .lightisle-switch-<taskID>.
	record, err := f.accounts.LoadStorageSwitchTask(f.memberID, resp.TaskID)
	if err != nil {
		t.Fatal(err)
	}
	var progress storageSwitchProgress
	if err := json.Unmarshal(record.Progress, &progress); err != nil {
		t.Fatal(err)
	}
	targetLease, err := f.server.AcquireRootServices(ctx, exfatRoot.ID)
	if err != nil {
		t.Fatal(err)
	}
	dstMgr := targetLease.Services.Files.(*files.Manager)
	stagedFiles, err := dstMgr.StagedStorageSwitchTree(ctx, resp.TaskID, "files")
	if err != nil {
		targetLease.Close()
		t.Fatal(err)
	}
	stagedPhotos, err := dstMgr.StagedStorageSwitchTree(ctx, resp.TaskID, "photos")
	targetLease.Close()
	if err != nil {
		t.Fatal(err)
	}
	progress.Phase = "interrupted"
	progress.Publishing = true
	progress.CanResume = true
	progress.ReadyToCleanup = false
	progress.Published = map[string]files.StorageSwitchTree{
		filesDir:  stagedFiles,
		photosDir: stagedPhotos,
	}
	progress.TrashIDs = map[string]string{
		"files":  "55555555555555555555555555555555",
		"photos": "66666666666666666666666666666666",
	}
	progress.Error = "storage_switch_failed"
	progress.ErrorDetail = "operation not supported"
	rawProgress, err := json.Marshal(progress)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.accounts.SaveStorageSwitchTask(resp.TaskID, rawProgress); err != nil {
		t.Fatal(err)
	}

	statusResp, err := f.server.ExecuteSwitchUserStorage(ctx, "", true, f.memberID, SwitchUserStorageRequest{
		TaskID: resp.TaskID,
		Phase:  "status",
	})
	if err != nil {
		t.Fatalf("status of interrupted ExFAT task: %v", err)
	}
	if !statusResp.CanResume || !statusResp.CanCancel {
		t.Fatalf("expected interrupted task with all categories still staged to allow both resume and cancel: %+v", statusResp)
	}

	resumeResp, err := f.server.ExecuteSwitchUserStorage(ctx, "", true, f.memberID, SwitchUserStorageRequest{
		TaskID: resp.TaskID,
		Phase:  "resume_publish",
	})
	if err != nil {
		t.Fatalf("resume_publish on ExFAT: %v", err)
	}
	for deadline := time.Now().Add(8 * time.Second); resumeResp.Phase != "completed"; {
		if resumeResp.Error != "" || time.Now().After(deadline) {
			t.Fatalf("ExFAT resume_publish did not complete: %+v", resumeResp)
		}
		time.Sleep(15 * time.Millisecond)
		resumeResp, err = f.server.ExecuteSwitchUserStorage(ctx, "", true, f.memberID, SwitchUserStorageRequest{
			TaskID: resp.TaskID,
			Phase:  "status",
		})
		if err != nil {
			t.Fatalf("poll ExFAT resume status: %v", err)
		}
	}
	if data, err := os.ReadFile(filepath.Join(exfatShare, filesDir, "doc.txt")); err != nil || string(data) != "exfat-payload" {
		t.Fatalf("expected doc.txt on ExFAT target after resume_publish: %v %q", err, string(data))
	}
	if info, err := os.Stat(filepath.Join(exfatShare, filesDir, "empty.txt")); err != nil || info.Size() != 0 {
		t.Fatalf("expected empty.txt on ExFAT target after resume_publish: %v %+v", err, info)
	}

	// Switch back from ExFAT to APFS using "move" mode to verify TrashStorageSwitch on ExFAT.
	moveBackReq := SwitchUserStorageRequest{
		TaskID:           "77777777777777777777777777777777",
		Categories:       []string{"files", "photos"},
		SourceRootID:     exfatRoot.ID,
		SourceGeneration: exfatRoot.Generation,
		TargetRootID:     f.rootB.ID,
		TargetGeneration: f.rootB.Generation,
		Mode:             "move",
		Phase:            "copy_and_verify",
	}
	backResp, err := f.server.ExecuteSwitchUserStorage(ctx, "", true, f.memberID, moveBackReq)
	if err != nil {
		t.Fatalf("start move back from ExFAT: %v", err)
	}
	for deadline := time.Now().Add(8 * time.Second); backResp.Phase != "completed"; {
		if backResp.Error != "" || time.Now().After(deadline) {
			t.Fatalf("move back from ExFAT did not complete: %+v", backResp)
		}
		time.Sleep(15 * time.Millisecond)
		backResp, err = f.server.ExecuteSwitchUserStorage(ctx, "", true, f.memberID, SwitchUserStorageRequest{
			TaskID: backResp.TaskID,
			Phase:  "status",
		})
		if err != nil {
			t.Fatalf("poll move back status: %v", err)
		}
	}
	if data, err := os.ReadFile(filepath.Join(f.pathB, filesDir, "doc.txt")); err != nil || string(data) != "exfat-payload" {
		t.Fatalf("expected doc.txt on APFS rootB after move from ExFAT: %v %q", err, string(data))
	}
}
