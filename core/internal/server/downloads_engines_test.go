package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/downloads"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/webarchive"
)

type multiEngineDownloadTestEnv struct {
	handler      http.Handler
	rootServer   *RootServer
	accounts     *auth.Store
	registry     *roots.Registry
	root         roots.Root
	shareDir     string
	adminCookie  *http.Cookie
	memberCookie *http.Cookie
	memberPath   string
}

func newMultiEngineDownloadTestEnv(
	t *testing.T,
	locateYtDlp func() (string, string, error),
	webArchiveOpts *webarchive.Options,
) (*multiEngineDownloadTestEnv, *downloads.Manager) {
	t.Helper()
	base := t.TempDir()
	dataDir := filepath.Join(base, "data")
	volume := filepath.Join(base, "volume")
	shareDir := filepath.Join(volume, "share")
	for _, dir := range []string{dataDir, volume, shareDir} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}

	registry, err := roots.OpenWithProvider(dataDir, rootRoutingProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	root, err := registry.Add(context.Background(), "HomeNAS", shareDir)
	if err != nil {
		t.Fatal(err)
	}
	accounts, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = accounts.Close() })
	if err := accounts.Setup("admin", "AdminPassword-2026!"); err != nil {
		t.Fatal(err)
	}
	adminToken, err := accounts.Login("admin", "AdminPassword-2026!")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(adminToken, "alice", "AlicePassword-2026!", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberToken, err := accounts.Login("alice", "AlicePassword-2026!")
	if err != nil {
		t.Fatal(err)
	}
	location, err := accounts.AssignUserStorage(adminToken, member.ID, auth.StorageFiles, root.ID, root.Generation)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(shareDir, filepath.FromSlash(location.RelativePath)), 0o700); err != nil {
		t.Fatal(err)
	}

	publisher := downloads.NewRegistryPublisher(registry, accounts)
	center, err := downloads.New(downloads.Options{
		DataDir:           dataDir,
		LocateYtDlp:       locateYtDlp,
		WebArchiveOptions: webArchiveOpts,
		Publisher:         publisher,
		CanImport: func(owner int64, destination string) bool {
			selected, ok := registry.Default()
			return ok && accounts.CanAccessRootForUser(owner, selected.ID, destination, true, false)
		},
		CanFetch: func(owner int64) bool {
			user, err := accounts.GetUser(owner)
			return err == nil && user.Enabled && user.Role == auth.RoleAdmin
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = center.Close() })

	srv := NewWithRoots("", accounts, nil, nil, nil, nil, registry,
		func(_ context.Context, _ roots.Root, lease *roots.Lease) (*RootServices, error) {
			mgr, err := files.NewPinnedManager(lease.Root)
			if err != nil {
				return nil, err
			}
			return &RootServices{Files: mgr}, nil
		},
		RootServerOptions{DownloadCenter: center},
	)
	t.Cleanup(func() { _ = srv.Close() })

	return &multiEngineDownloadTestEnv{
		handler:      srv,
		rootServer:   srv,
		accounts:     accounts,
		registry:     registry,
		root:         root,
		shareDir:     shareDir,
		adminCookie:  &http.Cookie{Name: sessionCookie, Value: adminToken},
		memberCookie: &http.Cookie{Name: sessionCookie, Value: memberToken},
		memberPath:   location.RelativePath,
	}, center
}

func (e *multiEngineDownloadTestEnv) call(method, target, body string, cookie *http.Cookie) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, strings.NewReader(body))
	req.RemoteAddr = "127.0.0.1:51234"
	if cookie != nil {
		req.AddCookie(cookie)
	}
	if method != http.MethodGet && method != http.MethodHead {
		req.Header.Set("X-LightIsle-Request", "1")
	}
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	return rec
}

func waitForHTTPDownloadTerminal(t *testing.T, env *multiEngineDownloadTestEnv, taskID string) downloads.Task {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		rec := env.call(http.MethodGet, "/api/v2/downloads", "", env.adminCookie)
		if rec.Code != http.StatusOK {
			t.Fatalf("list downloads: %d %s", rec.Code, rec.Body.String())
		}
		var payload struct {
			Tasks []downloads.Task `json:"tasks"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
			t.Fatal(err)
		}
		for _, task := range payload.Tasks {
			if task.ID == taskID && (task.Status == downloads.StatusCompleted || task.Status == downloads.StatusFailed || task.Status == downloads.StatusCancelled) {
				return task
			}
		}
		time.Sleep(30 * time.Millisecond)
	}
	t.Fatalf("download task %s did not finish in time", taskID)
	return downloads.Task{}
}

func TestDownloadStatusExposesAllEnginesAndBackwardCompat(t *testing.T) {
	var ytdlpPath atomic.Value
	ytdlpPath.Store("")

	env, _ := newMultiEngineDownloadTestEnv(t, func() (string, string, error) {
		p := ytdlpPath.Load().(string)
		if p == "" {
			return "", "", os.ErrNotExist
		}
		return p, "2025.03.26", nil
	}, nil)

	rec := env.call(http.MethodGet, "/api/v2/downloads/status", "", env.adminCookie)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d %s", rec.Code, rec.Body.String())
	}
	var status struct {
		Available           bool   `json:"available"`
		Version             string `json:"version"`
		Reason              string `json:"reason"`
		Aria2Available      bool   `json:"aria2Available"`
		Aria2Version        string `json:"aria2Version"`
		Aria2Reason         string `json:"aria2Reason"`
		YtDlpAvailable      bool   `json:"ytdlpAvailable"`
		YtDlpVersion        string `json:"ytdlpVersion"`
		YtDlpReason         string `json:"ytdlpReason"`
		WebArchiveAvailable bool   `json:"webArchiveAvailable"`
		NetworkAllowed      bool   `json:"networkAllowed"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if status.Available || status.Aria2Available || status.Reason != "aria2_not_installed" || status.Aria2Reason != "aria2_not_installed" {
		t.Fatalf("unexpected aria2 status: %+v", status)
	}
	if status.YtDlpAvailable || status.YtDlpReason != "ytdlp_not_installed" {
		t.Fatalf("unexpected initial ytdlp status: %+v", status)
	}
	if !status.WebArchiveAvailable || !status.NetworkAllowed {
		t.Fatalf("expected webArchiveAvailable=true and networkAllowed=true, got %+v", status)
	}

	// Member sees networkAllowed=false while still seeing engine status.
	memberRec := env.call(http.MethodGet, "/api/v2/downloads/status", "", env.memberCookie)
	if memberRec.Code != http.StatusOK || !strings.Contains(memberRec.Body.String(), `"networkAllowed":false`) {
		t.Fatalf("member status = %d %s", memberRec.Code, memberRec.Body.String())
	}

	// Hot-probe yt-dlp installation without Core restart.
	ytdlpPath.Store("/opt/homebrew/bin/yt-dlp")
	rec2 := env.call(http.MethodGet, "/api/v2/downloads/status", "", env.adminCookie)
	if rec2.Code != http.StatusOK {
		t.Fatalf("hot-probed status = %d %s", rec2.Code, rec2.Body.String())
	}
	status = struct {
		Available           bool   `json:"available"`
		Version             string `json:"version"`
		Reason              string `json:"reason"`
		Aria2Available      bool   `json:"aria2Available"`
		Aria2Version        string `json:"aria2Version"`
		Aria2Reason         string `json:"aria2Reason"`
		YtDlpAvailable      bool   `json:"ytdlpAvailable"`
		YtDlpVersion        string `json:"ytdlpVersion"`
		YtDlpReason         string `json:"ytdlpReason"`
		WebArchiveAvailable bool   `json:"webArchiveAvailable"`
		NetworkAllowed      bool   `json:"networkAllowed"`
	}{}
	if err := json.Unmarshal(rec2.Body.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if !status.YtDlpAvailable || status.YtDlpVersion != "2025.03.26" || status.YtDlpReason != "" {
		t.Fatalf("hot-probed ytdlp status mismatch: %+v", status)
	}
}

func TestDownloadCreateYtDlpMissingMockAndPermissions(t *testing.T) {
	mockBin := filepath.Join(t.TempDir(), "mock-yt-dlp")
	script := `#!/bin/sh
set -eu
out_dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paths) out_dir="$2"; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
printf 'video-bytes-payload' > "$out_dir/clip.mp4"
`
	if err := os.WriteFile(mockBin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	var ytdlpReady atomic.Bool
	env, _ := newMultiEngineDownloadTestEnv(t, func() (string, string, error) {
		if !ytdlpReady.Load() {
			return "", "", os.ErrNotExist
		}
		return mockBin, "2025.03.26", nil
	}, nil)

	// Non-admin member cannot create ytdlp or webarchive tasks even with write grant.
	for _, engine := range []string{"ytdlp", "webarchive"} {
		res := env.call(http.MethodPost, "/api/v2/downloads",
			`{"engine":"`+engine+`","url":"https://example.com/item","destination":"`+env.memberPath+`"}`, env.memberCookie)
		if res.Code != http.StatusForbidden || !strings.Contains(res.Body.String(), "admin_only") {
			t.Fatalf("member created %s task: %d %s", engine, res.Code, res.Body.String())
		}
	}

	// Unknown engine, unknown fields, and invalid options are rejected with 400.
	for _, badBody := range []string{
		`{"engine":"curl","url":"https://example.com/x","destination":"."}`,
		`{"engine":"ytdlp","url":"https://example.com/x","destination":".","unknown":1}`,
		`{"engine":"ytdlp","url":"--exec=id","destination":"."}`,
		`{"engine":"ytdlp","url":"https://example.com/x","destination":".","options":{"format":"8k"}}`,
		`{"engine":"ytdlp","url":"https://example.com/x","destination":".","options":{"allowPlaylist":true,"playlistMaxItems":21}}`,
	} {
		res := env.call(http.MethodPost, "/api/v2/downloads", badBody, env.adminCookie)
		if res.Code != http.StatusBadRequest || !strings.Contains(res.Body.String(), "download_invalid_request") {
			t.Fatalf("bad body %s => %d %s", badBody, res.Code, res.Body.String())
		}
	}

	// Missing yt-dlp returns 503 ytdlp_not_installed with localized Chinese guidance.
	missingRes := env.call(http.MethodPost, "/api/v2/downloads",
		`{"engine":"ytdlp","url":"https://example.com/watch?v=1","destination":"."}`, env.adminCookie)
	if missingRes.Code != http.StatusServiceUnavailable {
		t.Fatalf("missing ytdlp status = %d %s", missingRes.Code, missingRes.Body.String())
	}
	var errPayload APIError
	if err := json.Unmarshal(missingRes.Body.Bytes(), &errPayload); err != nil {
		t.Fatal(err)
	}
	if errPayload.Error != "ytdlp_not_installed" || !strings.Contains(errPayload.NextAction, "brew install yt-dlp") {
		t.Fatalf("unexpected ytdlp_not_installed error envelope: %+v", errPayload)
	}

	// Enabling yt-dlp allows task creation and publication without aria2.
	ytdlpReady.Store(true)
	createRes := env.call(http.MethodPost, "/api/v2/downloads",
		`{"engine":"ytdlp","url":"https://example.com/watch?v=ok","destination":"`+env.memberPath+`","options":{"allowPlaylist":true,"playlistMaxItems":5,"format":"1080p"}}`,
		env.adminCookie)
	if createRes.Code != http.StatusAccepted {
		t.Fatalf("create ytdlp = %d %s", createRes.Code, createRes.Body.String())
	}
	var created struct {
		Task downloads.Task `json:"task"`
	}
	if err := json.Unmarshal(createRes.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created.Task.Engine != downloads.EngineYtDlp || created.Task.Options == nil || !created.Task.Options.AllowPlaylist || created.Task.Options.PlaylistMaxItems != 5 || created.Task.Options.Format != "1080p" {
		t.Fatalf("unexpected created task payload: %+v", created.Task)
	}
	done := waitForHTTPDownloadTerminal(t, env, created.Task.ID)
	if done.Status != downloads.StatusCompleted || done.Filename != "clip.mp4" {
		t.Fatalf("unexpected completed ytdlp task: %+v", done)
	}
	published, err := os.ReadFile(filepath.Join(env.shareDir, filepath.FromSlash(env.memberPath), "clip.mp4"))
	if err != nil || string(published) != "video-bytes-payload" {
		t.Fatalf("published ytdlp clip mismatch: %q %v", published, err)
	}

	// Cancelling/failing a yt-dlp task and retrying after yt-dlp is removed returns ytdlp_not_installed.
	failingRes := env.call(http.MethodPost, "/api/v2/downloads",
		`{"engine":"ytdlp","url":"https://example.com/watch?v=retry","destination":"`+env.memberPath+`"}`,
		env.adminCookie)
	if failingRes.Code != http.StatusAccepted {
		t.Fatalf("create second ytdlp = %d %s", failingRes.Code, failingRes.Body.String())
	}
	var secondCreated struct {
		Task downloads.Task `json:"task"`
	}
	if err := json.Unmarshal(failingRes.Body.Bytes(), &secondCreated); err != nil {
		t.Fatal(err)
	}
	_ = waitForHTTPDownloadTerminal(t, env, secondCreated.Task.ID)
	cancelOrRetry := env.call(http.MethodPost, "/api/v2/downloads",
		`{"engine":"ytdlp","url":"https://example.com/watch?v=gone","destination":"."}`,
		env.adminCookie)
	if cancelOrRetry.Code != http.StatusAccepted {
		t.Fatalf("create third ytdlp = %d %s", cancelOrRetry.Code, cancelOrRetry.Body.String())
	}
	var thirdCreated struct {
		Task downloads.Task `json:"task"`
	}
	if err := json.Unmarshal(cancelOrRetry.Body.Bytes(), &thirdCreated); err != nil {
		t.Fatal(err)
	}
	_ = env.call(http.MethodPost, "/api/v2/downloads/"+thirdCreated.Task.ID+"/actions", `{"action":"cancel"}`, env.adminCookie)
	_ = waitForHTTPDownloadTerminal(t, env, thirdCreated.Task.ID)
	ytdlpReady.Store(false)
	retryMissing := env.call(http.MethodPost, "/api/v2/downloads/"+thirdCreated.Task.ID+"/actions", `{"action":"retry"}`, env.adminCookie)
	if retryMissing.Code != http.StatusServiceUnavailable || !strings.Contains(retryMissing.Body.String(), "ytdlp_not_installed") {
		t.Fatalf("retry without ytdlp = %d %s", retryMissing.Code, retryMissing.Body.String())
	}

	// Default / aria2 engine still reports download_unavailable when aria2 is absent.
	aria2Res := env.call(http.MethodPost, "/api/v2/downloads",
		`{"url":"https://example.com/file.zip","destination":"."}`, env.adminCookie)
	if aria2Res.Code != http.StatusServiceUnavailable || !strings.Contains(aria2Res.Body.String(), "download_unavailable") {
		t.Fatalf("aria2 without binary = %d %s", aria2Res.Code, aria2Res.Body.String())
	}
}

func TestDownloadCreateWebArchiveEndToEndAndSSRFBlocked(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = io.WriteString(w, `<html><head><title>Family Recipe</title></head><body><p>Soup</p><script>evil()</script></body></html>`)
	}))
	defer srv.Close()

	// Production default WebArchiveOptions=nil blocks loopback SSRF even over HTTP API.
	strictEnv, _ := newMultiEngineDownloadTestEnv(t, nil, nil)
	blockedRes := strictEnv.call(http.MethodPost, "/api/v2/downloads",
		`{"engine":"webarchive","url":"`+srv.URL+`","destination":"."}`, strictEnv.adminCookie)
	if blockedRes.Code != http.StatusAccepted {
		t.Fatalf("blocked webarchive create = %d %s", blockedRes.Code, blockedRes.Body.String())
	}
	var blockedCreated struct {
		Task downloads.Task `json:"task"`
	}
	if err := json.Unmarshal(blockedRes.Body.Bytes(), &blockedCreated); err != nil {
		t.Fatal(err)
	}
	blockedDone := waitForHTTPDownloadTerminal(t, strictEnv, blockedCreated.Task.ID)
	if blockedDone.Status != downloads.StatusFailed || blockedDone.Error != webarchive.ErrBlockedAddress.Error() {
		t.Fatalf("expected SSRF failure, got %+v", blockedDone)
	}

	// With explicit test AllowHosts, webarchive works independently without aria2 or yt-dlp.
	env, _ := newMultiEngineDownloadTestEnv(t, nil, &webarchive.Options{AllowHosts: []string{"127.0.0.1", "::1"}})
	res := env.call(http.MethodPost, "/api/v2/downloads",
		`{"engine":"webarchive","url":"`+srv.URL+`","destination":"`+env.memberPath+`"}`, env.adminCookie)
	if res.Code != http.StatusAccepted {
		t.Fatalf("create webarchive = %d %s", res.Code, res.Body.String())
	}
	var created struct {
		Task downloads.Task `json:"task"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	done := waitForHTTPDownloadTerminal(t, env, created.Task.ID)
	if done.Status != downloads.StatusCompleted || done.Engine != downloads.EngineWebArchive || done.Filename != "Family Recipe.html" {
		t.Fatalf("unexpected webarchive task result: %+v", done)
	}
	raw, err := os.ReadFile(filepath.Join(env.shareDir, filepath.FromSlash(env.memberPath), "Family Recipe.html"))
	if err != nil || !strings.Contains(string(raw), "Soup") || strings.Contains(string(raw), "<script") {
		t.Fatalf("archived html content mismatch: %q %v", raw, err)
	}
}

func TestDownloadEngineErrorCatalogHasChineseGuidance(t *testing.T) {
	codes := []string{
		"ytdlp_not_installed",
		"webarchive_invalid_url",
		"webarchive_blocked_address",
		"webarchive_too_many_redirects",
		"webarchive_too_large",
		"webarchive_unsupported_content_type",
		"webarchive_http_error",
		"webarchive_timeout",
	}
	for _, code := range codes {
		rec := httptest.NewRecorder()
		writeAPIErrorCode(rec, http.StatusServiceUnavailable, code)
		var parsed APIError
		if err := json.Unmarshal(rec.Body.Bytes(), &parsed); err != nil {
			t.Fatalf("%s unmarshal failed: %v", code, err)
		}
		if parsed.Error != code || parsed.Message == "" || parsed.NextAction == "" || parsed.DataSafe == nil || !*parsed.DataSafe {
			t.Fatalf("%s missing catalog guidance: %+v", code, parsed)
		}
	}
}
