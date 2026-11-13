package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/apps"
	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/automation"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
	"github.com/lengsukq/lightisle/core/internal/notify"
)

func TestAutomationIsolatesPluginCronAndLaunchRedactsForMember(t *testing.T) {
	dataDir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	adminTok, err := accounts.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	memberUser, err := accounts.CreateUser(adminTok, "alice", "alice-password-12345", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberTok, err := accounts.Login("alice", "alice-password-12345")
	if err != nil {
		t.Fatal(err)
	}

	// 1. Standalone script task with agent-owned notification.email
	scriptFolder := filepath.Join(dataDir, "automation", "scripts", "daily-report")
	if err := os.MkdirAll(scriptFolder, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scriptFolder, "run.sh"), []byte("#!/bin/sh\necho ok\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scriptFolder, "email.html"), []byte("<p>{{run.state}}</p>"), 0600); err != nil {
		t.Fatal(err)
	}
	scriptDoc := `{"schemaVersion":1,"id":"daily-report","name":"日报","enabled":true,"entry":"run.sh","schedule":{"cron":"0 8 * * *","timezone":"Asia/Shanghai"},"notification":{"events":["failure"],"channels":["email"],"email":{"mode":"content","file":"email.html","subject":"日报通知"}}}`
	if err := os.WriteFile(filepath.Join(scriptFolder, "task.json"), []byte(scriptDoc), 0600); err != nil {
		t.Fatal(err)
	}

	// 2. App Center plugin with both static web and cron
	pluginDir := filepath.Join(dataDir, "plugins", "family-helper")
	if err := os.MkdirAll(filepath.Join(pluginDir, "ui"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "ui", "index.html"), []byte("<h1>Helper</h1>"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "run-cron.sh"), []byte("#!/bin/sh\necho app-cron\n"), 0700); err != nil {
		t.Fatal(err)
	}
	pluginManifest := fmt.Sprintf(`{"schemaVersion":2,"id":"family-helper","name":"家庭助手","version":"1.0.0","access":{"policy":"selected_members","allowedUserIDs":[%d]},"web":{"enabled":true,"mode":"static","entry":"ui/index.html","basePath":"/apps/family-helper"},"cron":{"enabled":true,"entry":"run-cron.sh","schedule":{"cron":"*/10 * * * *","timezone":"Asia/Shanghai"},"timeoutSeconds":30,"notification":{"events":["failure"],"channels":["bark"]}}}`, memberUser.ID)
	if err := os.WriteFile(filepath.Join(pluginDir, "plugin.json"), []byte(pluginManifest), 0600); err != nil {
		t.Fatal(err)
	}

	autoMgr, err := automation.New(dataDir, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer autoMgr.Close()
	appsMgr := apps.NewManager(dataDir, "lightisled", autoMgr)
	defer appsMgr.Close()
	if err := appsMgr.Reload(); err != nil {
		t.Fatal(err)
	}
	hub, err := notify.New(notify.Config{})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()

	handler := WithApps(WithAutomation(New("", accounts, nil), accounts, autoMgr, hub), "", accounts, appsMgr)
	call := func(method, path, session string, body string) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		if session != "" {
			req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		if method != http.MethodGet {
			req.Header.Set("X-LightIsle-Request", "1")
			req.Header.Set("Content-Type", "application/json")
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}

	// Automation task list & refresh must NEVER expose App Center plugin cron ("app-family-helper").
	for _, m := range []struct{ method, path string }{
		{http.MethodGet, "/api/v2/automation/tasks"},
		{http.MethodPost, "/api/v2/automation/refresh"},
	} {
		res := call(m.method, m.path, adminTok, `{}`)
		if res.Code != http.StatusOK {
			t.Fatalf("%s %s failed: %d %s", m.method, m.path, res.Code, res.Body.String())
		}
		if !strings.Contains(res.Body.String(), `"daily-report"`) || strings.Contains(res.Body.String(), "family-helper") {
			t.Fatalf("%s %s leaked plugin cron or missed script task: %s", m.method, m.path, res.Body.String())
		}
	}

	// Direct PUT / DELETE / GET runs / POST run on "app-family-helper" via /api/v2/automation must 404.
	for _, op := range []struct{ method, path, body string }{
		{http.MethodGet, "/api/v2/automation/tasks/app-family-helper/runs", ""},
		{http.MethodPost, "/api/v2/automation/tasks/app-family-helper/run", `{}`},
		{http.MethodPut, "/api/v2/automation/tasks/app-family-helper", `{"enabled":false,"schedule":{"cron":"0 9 * * *","timezone":"UTC"},"notification":{"events":["failure"],"channels":[]}}`},
		{http.MethodDelete, "/api/v2/automation/tasks/app-family-helper", ""},
	} {
		res := call(op.method, op.path, adminTok, op.body)
		if res.Code != http.StatusNotFound || !strings.Contains(res.Body.String(), "automation_task_not_found") {
			t.Fatalf("expected 404 automation_task_not_found for %s %s, got %d %s", op.method, op.path, res.Code, res.Body.String())
		}
	}

	// Member POST /api/v2/apps/family-helper/launch must redact cron, host paths, and allowedUserIDs!
	resLaunch := call(http.MethodPost, "/api/v2/apps/family-helper/launch", memberTok, `{}`)
	if resLaunch.Code != http.StatusOK {
		t.Fatalf("member launch family-helper failed: %d %s", resLaunch.Code, resLaunch.Body.String())
	}
	rawLaunch := resLaunch.Body.String()
	if strings.Contains(rawLaunch, dataDir) ||
		strings.Contains(rawLaunch, `"pluginsDir"`) ||
		strings.Contains(rawLaunch, `"pluginDataDir"`) ||
		strings.Contains(rawLaunch, `"hasCron":true`) ||
		strings.Contains(rawLaunch, "*/10 * * * *") ||
		strings.Contains(rawLaunch, fmt.Sprintf("[%d]", memberUser.ID)) {
		t.Fatalf("member /launch leaked admin/cron/path metadata: %s", rawLaunch)
	}
}

func TestComputerFilesProtectsExternalAppCenterStorageSecrets(t *testing.T) {
	hostRoot, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	dataDir := filepath.Join(hostRoot, "core-data")
	extParent := filepath.Join(hostRoot, "ExternalDrive", "SharedDocs")
	extAppsDir := filepath.Join(extParent, "LightIsleApps")
	if err := os.MkdirAll(extParent, 0700); err != nil {
		t.Fatal(err)
	}
	normalFile := filepath.Join(extParent, "readme.txt")
	if err := os.WriteFile(normalFile, []byte("public-family-doc"), 0600); err != nil {
		t.Fatal(err)
	}

	accounts, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	adminTok, err := accounts.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	memberUser, err := accounts.CreateUser(adminTok, "bob", "bob-password-12345", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberTok, err := accounts.Login("bob", "bob-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	if err := accounts.SetComputerFilesEnabled(true); err != nil {
		t.Fatal(err)
	}

	appsMgr := apps.NewManager(dataDir, "lightisled", nil)
	defer appsMgr.Close()
	appsMgr.SetStoragePolicyForTesting(nil, []string{filepath.Join(hostRoot, "ExternalDrive")})
	if err := appsMgr.Reload(); err != nil {
		t.Fatal(err)
	}
	if _, err := appsMgr.MutateStorageLocation(apps.AppStorageMutationRequest{
		Action: "add",
		Kind:   apps.AppStorageKindExternal,
		Path:   extAppsDir,
	}); err != nil {
		t.Fatalf("add external app storage failed: %v", err)
	}
	secretEnv := filepath.Join(extAppsDir, "plugins", "secret-app", "env.json")
	if err := os.MkdirAll(filepath.Dir(secretEnv), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(secretEnv, []byte(`{"API_KEY":"top-secret"}`), 0600); err != nil {
		t.Fatal(err)
	}

	handler := WithApps(New("", accounts, nil), "", accounts, appsMgr)
	call := func(method, path, session, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("X-LightIsle-Request", "1")
		req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}

	grantBody := fmt.Sprintf(`{"mode":"folders","paths":[%q]}`, extParent)
	if w := call(http.MethodPut, fmt.Sprintf("/api/v2/computer-files/grants/%d", memberUser.ID), adminTok, grantBody); w.Code != http.StatusOK {
		t.Fatalf("grant computer_files failed: %d %s", w.Code, w.Body.String())
	}
	if w := call(http.MethodGet, "/api/v2/computer-files/content?path="+url.QueryEscape(normalFile), memberTok, ""); w.Code != http.StatusOK {
		t.Fatalf("expected member read normal file 200, got %d %s", w.Code, w.Body.String())
	}
	for _, tok := range []string{memberTok, adminTok} {
		if w := call(http.MethodGet, "/api/v2/computer-files/content?path="+url.QueryEscape(secretEnv), tok, ""); w.Code != http.StatusForbidden {
			t.Fatalf("expected 403 reading external app env.json via computer_files, got %d %s", w.Code, w.Body.String())
		}
	}
}

func TestRootPublicShareBlocksCrossMemberHomeAndPersonShareHonorsOwnerDisable(t *testing.T) {
	f := newRootRoutingFixture(t)

	// Allocate personal storage for member1 (f.memberID) and member2 (bob).
	bobUser, err := f.accounts.CreateUser(f.admin, "bob", "bob-password-12345", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	bobTok, err := f.accounts.Login("bob", "bob-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	for _, uid := range []int64{f.memberID, bobUser.ID} {
		alloc := f.call(f.admin, http.MethodPost, rootRoute(f.rootA.ID, fmt.Sprintf("/users/%d/storage", uid)), `{"categories":["files","photos","videos"]}`)
		if alloc.Code != http.StatusOK && alloc.Code != http.StatusCreated {
			t.Fatalf("alloc user %d storage: %d %s", uid, alloc.Code, alloc.Body.String())
		}
	}

	ts := time.Date(2026, 10, 1, 10, 0, 0, 0, time.UTC)
	aliceTripPhotoRel := fmt.Sprintf("Users/u%d/photos/Trip/family.png", f.memberID)
	writeServerTestPNG(t, filepath.Join(f.pathA, filepath.FromSlash(aliceTripPhotoRel)), ts)

	// Share Alice's Trip folder album with Bob AND even give Bob a broad "." read grant:
	// Bob STILL must not be able to publish an anonymous public bearer link inside Alice's personal home!
	if _, err := f.accounts.ShareFolderAlbum(f.member, f.rootA.ID, f.rootA.Generation, "Trip", "AliceTrip", bobUser.ID, false); err != nil {
		t.Fatalf("ShareFolderAlbum failed: %v", err)
	}
	if err := f.accounts.SetRootGrant(f.admin, bobUser.ID, f.rootA.ID, ".", false); err != nil {
		t.Fatalf("SetRootGrant '.' failed: %v", err)
	}
	bobPublicShare := f.call(bobTok, http.MethodPost, rootRoute(f.rootA.ID, "/file-shares"),
		fmt.Sprintf(`{"path":%q,"hours":1}`, aliceTripPhotoRel))
	if bobPublicShare.Code != http.StatusForbidden {
		t.Fatalf("expected 403 when Bob creates anonymous public share on Alice's personal home, got %d %s", bobPublicShare.Code, bobPublicShare.Body.String())
	}
	alicePublicShare := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/file-shares"),
		fmt.Sprintf(`{"path":%q,"hours":1}`, aliceTripPhotoRel))
	if alicePublicShare.Code != http.StatusCreated {
		t.Fatalf("expected 201 when Alice creates public share on her own photo, got %d %s", alicePublicShare.Code, alicePublicShare.Body.String())
	}

	// Person share: Alice indexes face cluster in her personal photos and shares with Bob.
	_ = f.call(f.admin, http.MethodGet, rootRoute(f.rootA.ID, "/photos/status"), "")
	lib := f.services[f.rootA.ID].Gallery
	lib.SetMediaWorker(&serverTestAIWorker{
		byName: map[string]mediaworker.AIAnalysis{
			"family.png": {
				Status: "ok",
				Faces: []mediaworker.AIFace{
					{BoxX: 0.2, BoxY: 0.2, BoxW: 0.4, BoxH: 0.4, Quality: 0.9, EyeOpenness: 0.8, ModelVersion: "anfr-v4-f32x128", Embedding: makeServerFaceBytes(3)},
				},
			},
		},
	})
	_ = f.call(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/photos/scan"), "")
	var personID int64
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		lib.TriggerAIIndex()
		pResp := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/photos/persons"), "")
		var payload struct {
			Persons []struct {
				ID int64 `json:"id"`
			} `json:"persons"`
		}
		_ = json.Unmarshal(pResp.Body.Bytes(), &payload)
		if len(payload.Persons) > 0 {
			personID = payload.Persons[0].ID
			break
		}
		time.Sleep(25 * time.Millisecond)
	}
	if personID == 0 {
		t.Fatal("expected person cluster for Alice")
	}

	shareCreate := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/photos/person-shares"),
		fmt.Sprintf(`{"personId":%d,"memberUserId":%d,"label":"宝宝"}`, personID, bobUser.ID))
	if shareCreate.Code != http.StatusCreated {
		t.Fatalf("create person share failed: %d %s", shareCreate.Code, shareCreate.Body.String())
	}
	var createdShare struct {
		Share struct {
			ID int64 `json:"id"`
		} `json:"share"`
	}
	_ = json.Unmarshal(shareCreate.Body.Bytes(), &createdShare)
	shareID := createdShare.Share.ID

	bobAssets := f.call(bobTok, http.MethodGet, rootRoute(f.rootA.ID, fmt.Sprintf("/photos/person-shares/%d/assets", shareID)), "")
	if bobAssets.Code != http.StatusOK || !strings.Contains(bobAssets.Body.String(), "family.png") {
		t.Fatalf("expected Bob to view shared person assets before disable, got %d %s", bobAssets.Code, bobAssets.Body.String())
	}
	var assetPayload struct {
		Assets []struct {
			ID int64 `json:"id"`
		} `json:"assets"`
	}
	_ = json.Unmarshal(bobAssets.Body.Bytes(), &assetPayload)
	assetID := assetPayload.Assets[0].ID

	// Disable Alice's account -> Bob must immediately lose incoming person share list & asset content (404).
	if err := f.accounts.SetEnabled(f.admin, f.memberID, false); err != nil {
		t.Fatalf("disable Alice failed: %v", err)
	}
	bobListAfter := f.call(bobTok, http.MethodGet, rootRoute(f.rootA.ID, "/photos/person-shares"), "")
	if strings.Contains(bobListAfter.Body.String(), "宝宝") {
		t.Fatalf("expected disabled owner's person share hidden from incoming list, got %s", bobListAfter.Body.String())
	}
	for _, suffix := range []string{
		fmt.Sprintf("/photos/person-shares/%d/assets", shareID),
		fmt.Sprintf("/photos/person-shares/%d/assets/%d/content", shareID, assetID),
		fmt.Sprintf("/photos/person-shares/%d/assets/%d/thumbnail", shareID, assetID),
	} {
		if got := f.call(bobTok, http.MethodGet, rootRoute(f.rootA.ID, suffix), ""); got.Code != http.StatusNotFound {
			t.Fatalf("expected 404 on %s after owner account disabled, got %d %s", suffix, got.Code, got.Body.String())
		}
	}
}
