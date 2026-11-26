package downloads

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"image"
	"image/color"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/webarchive"
)

func waitForTaskTerminal(t *testing.T, m *Manager, owner int64, id string) Task {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		task, err := m.taskByID(id, owner)
		if err != nil {
			t.Fatal(err)
		}
		switch task.Status {
		case StatusCompleted, StatusFailed, StatusCancelled:
			return task
		}
		time.Sleep(30 * time.Millisecond)
	}
	t.Fatalf("task %s did not reach terminal state in time", id)
	return Task{}
}

func waitForTaskRunning(t *testing.T, m *Manager, owner int64, id string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		task, err := m.taskByID(id, owner)
		if err != nil {
			t.Fatal(err)
		}
		if task.Status == StatusRunning {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("task %s never reached running state", id)
}

func TestLegacySQLiteMigratesEngineAndOptionsColumns(t *testing.T) {
	dir := t.TempDir()
	store, err := files.Open(filepath.Join(dir, "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	// Create a pre-migration download_tasks table without engine/options_json.
	db, err := sql.Open("sqlite3", filepath.Join(dir, "downloads.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE download_tasks(
		id TEXT PRIMARY KEY,
		owner INTEGER NOT NULL,
		url TEXT NOT NULL,
		destination TEXT NOT NULL,
		max_bytes INTEGER NOT NULL DEFAULT 0,
		status TEXT NOT NULL,
		gid TEXT NOT NULL DEFAULT '',
		root_binding TEXT,
		root_id TEXT NOT NULL DEFAULT '',
		root_generation INTEGER NOT NULL DEFAULT 0,
		phase TEXT NOT NULL DEFAULT 'download',
		filename TEXT NOT NULL DEFAULT '',
		total_bytes INTEGER NOT NULL DEFAULT 0,
		completed_bytes INTEGER NOT NULL DEFAULT 0,
		error TEXT NOT NULL DEFAULT '',
		created_at INTEGER NOT NULL,
		updated_at INTEGER NOT NULL,
		completed_at INTEGER NOT NULL DEFAULT 0);
		INSERT INTO download_tasks(id,owner,url,destination,status,created_at,updated_at)
		VALUES('legacy-1', 7, 'https://example.org/a.zip', '.', 'completed', 100, 100);`)
	if err != nil {
		t.Fatal(err)
	}
	_ = db.Close()

	m, err := New(testOptions(t, dir, store))
	if err != nil {
		t.Fatalf("migration open failed: %v", err)
	}
	defer m.Close()

	tasks, err := m.List(7)
	if err != nil || len(tasks) != 1 {
		t.Fatalf("list after migration: %+v %v", tasks, err)
	}
	if tasks[0].Engine != EngineAria2 || tasks[0].Options != nil {
		t.Fatalf("unexpected migrated task: %+v", tasks[0])
	}
}

func TestStatusHotProbesYtDlpAndWebArchiveWithoutAria2(t *testing.T) {
	dir := t.TempDir()
	store, err := files.Open(filepath.Join(dir, "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	var ytdlpPath atomic.Value
	ytdlpPath.Store("")

	opts := testOptions(t, dir, store)
	opts.LocateYtDlp = func() (string, string, error) {
		p := ytdlpPath.Load().(string)
		if p == "" {
			return "", "", errors.New("ytdlp_not_installed")
		}
		return p, "2025.03.26", nil
	}
	m, err := New(opts)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()

	st := m.Status()
	if st.Aria2Available || st.YtDlpAvailable || !st.WebArchiveAvailable {
		t.Fatalf("unexpected initial status: %+v", st)
	}
	if _, err := m.CreateWithEngine(1, EngineYtDlp, "https://example.com/v", ".", 0, EngineOptions{}); !errors.Is(err, ErrYtDlpNotAvailable) || !errors.Is(err, ErrNotAvailable) {
		t.Fatalf("expected ErrYtDlpNotAvailable wrapping ErrNotAvailable, got %v", err)
	}

	ytdlpPath.Store("/opt/homebrew/bin/yt-dlp")
	st = m.Status()
	if st.Aria2Available || !st.YtDlpAvailable || st.YtDlpVersion != "2025.03.26" || !st.WebArchiveAvailable {
		t.Fatalf("unexpected hot-probed status: %+v", st)
	}
}

func TestYtDlpURLAndArgsPreventFlagInjection(t *testing.T) {
	for _, bad := range []string{
		"",
		"--exec=whoami",
		"-o /tmp/pwn",
		"file:///etc/passwd",
		"ftp://example.com/video.mp4",
		"magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
		"https://user:pass@example.com/watch?v=1",
		"https://example.com/watch?v=1 --exec id",
		"https://example.com/\n--exec",
	} {
		if err := ValidateYtDlpURL(bad); !errors.Is(err, ErrInput) {
			t.Errorf("unsafe yt-dlp URL accepted: %q (%v)", bad, err)
		}
	}

	args, err := buildYtDlpArgs("/tmp/stage", "https://example.com/watch?v=abc", 1024, EngineOptions{})
	if err != nil {
		t.Fatalf("buildYtDlpArgs default failed: %v", err)
	}
	if !slices.Contains(args, "--no-playlist") || !slices.Contains(args, "--no-exec") || !slices.Contains(args, "--ignore-config") {
		t.Fatalf("missing safety flags: %v", args)
	}
	if len(args) < 2 || args[len(args)-2] != "--" || args[len(args)-1] != "https://example.com/watch?v=abc" {
		t.Fatalf("missing -- url separator: %v", args)
	}

	playlistArgs, err := buildYtDlpArgs("/tmp/stage", "https://example.com/list", 0, EngineOptions{
		AllowPlaylist: true, PlaylistMaxItems: 12, Format: "1080p",
	})
	if err != nil {
		t.Fatalf("buildYtDlpArgs playlist failed: %v", err)
	}
	if !slices.Contains(playlistArgs, "--yes-playlist") || !slices.Contains(playlistArgs, "--playlist-end") || !slices.Contains(playlistArgs, "12") {
		t.Fatalf("playlist flags missing: %v", playlistArgs)
	}

	if _, err := ValidateEngineOptions(EngineYtDlp, EngineOptions{AllowPlaylist: true, PlaylistMaxItems: 21}); !errors.Is(err, ErrInput) {
		t.Fatalf("playlist limit > 20 accepted: %v", err)
	}
	if _, err := ValidateEngineOptions(EngineYtDlp, EngineOptions{Format: "best;rm -rf /"}); !errors.Is(err, ErrInput) {
		t.Fatalf("arbitrary format string accepted: %v", err)
	}
}

func setupScopedRegistryEnv(t *testing.T) (data, volume string, reg *roots.Registry, accounts *auth.Store, owner auth.User, member auth.User, session string, root roots.Root, locationPath string) {
	t.Helper()
	base := t.TempDir()
	data, volume = filepath.Join(base, "data"), filepath.Join(base, "disk")
	for _, d := range []string{data, volume} {
		if err := os.Mkdir(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	var err error
	reg, err = roots.OpenWithProvider(data, publisherIdentityProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	root, err = reg.Add(context.Background(), "disk", volume)
	if err != nil {
		t.Fatal(err)
	}
	accounts, err = auth.Open(filepath.Join(data, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = accounts.Close() })
	if err := accounts.Setup("admin", "admin-password-2026"); err != nil {
		t.Fatal(err)
	}
	session, err = accounts.Login("admin", "admin-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	var ok bool
	owner, ok = accounts.Identity(session)
	if !ok {
		t.Fatal("missing admin identity")
	}
	member, err = accounts.CreateUser(session, "alice", "alice-password-2026", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	location, err := accounts.AssignUserStorage(session, member.ID, auth.StorageFiles, root.ID, root.Generation)
	if err != nil {
		t.Fatal(err)
	}
	locationPath = location.RelativePath
	if err := os.MkdirAll(filepath.Join(volume, filepath.FromSlash(locationPath)), 0o700); err != nil {
		t.Fatal(err)
	}
	return
}

func TestYtDlpEndToEndWithRootPublisherQuotaAndCancel(t *testing.T) {
	data, volume, reg, accounts, owner, member, session, root, locationPath := setupScopedRegistryEnv(t)

	// Fake yt-dlp binary that verifies flags and writes a media file into --paths.
	mockBin := filepath.Join(data, "mock-yt-dlp")
	script := `#!/bin/sh
set -eu
out_dir=""
saw_sep=0
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paths) out_dir="$2"; shift 2 ;;
    --) saw_sep=1; shift; url="${1:-}"; break ;;
    *) shift ;;
  esac
done
if [ "$saw_sep" -ne 1 ] || [ -z "$out_dir" ]; then
  echo "missing separator or paths" >&2
  exit 2
fi
case "$url" in
  *slow*)
    echo "[download]  10.0% of   10.00MiB"
    sleep 30
    exit 0
    ;;
esac
echo "[download]  50.0% of   1.00KiB"
printf 'fake-mp4-video-payload-1234567890' > "$out_dir/demo_clip.mp4"
echo "[download] 100.0% of   1.00KiB"
`
	if err := os.WriteFile(mockBin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	publisher := NewRegistryPublisher(reg, accounts)
	var publishedEvents []string
	publisher.SetOnPublished(func(rootID, target string) {
		publishedEvents = append(publishedEvents, rootID+":"+target)
	})

	var allowImport atomic.Bool
	allowImport.Store(true)
	// Deliberately leave aria2 Binary empty to prove yt-dlp works independently.
	m, err := New(Options{
		DataDir:     data,
		YtDlpBinary: mockBin,
		Publisher:   publisher,
		CanImport:   func(int64, string) bool { return allowImport.Load() },
		CanFetch:    func(uid int64) bool { return uid == owner.ID },
	})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()

	// Non-admin cannot fetch.
	if _, err := m.CreateWithEngine(member.ID, EngineYtDlp, "https://example.com/v", locationPath, 0, EngineOptions{}); !errors.Is(err, ErrFetchForbidden) {
		t.Fatalf("non-admin ytdlp fetch allowed: %v", err)
	}

	// Quota exceeded fails publication cleanly without writing target file.
	if err := accounts.SetUserStorageRootQuota(session, member.ID, root.ID, root.Generation, 10); err != nil {
		t.Fatal(err)
	}
	overQuota, err := m.CreateWithEngine(owner.ID, EngineYtDlp, "https://example.com/v1", locationPath, 0, EngineOptions{})
	if err != nil {
		t.Fatalf("create ytdlp task failed: %v", err)
	}
	overDone := waitForTaskTerminal(t, m, owner.ID, overQuota.ID)
	if overDone.Status != StatusFailed || overDone.Error != "storage_quota_exceeded" {
		t.Fatalf("expected quota failure, got %+v", overDone)
	}

	// Raise quota and retry — resumes from publishing phase or re-downloads and succeeds.
	if err := accounts.SetUserStorageRootQuota(session, member.ID, root.ID, root.Generation, 4096); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Action(owner.ID, overQuota.ID, "retry"); err != nil {
		t.Fatalf("retry ytdlp task failed: %v", err)
	}
	done := waitForTaskTerminal(t, m, owner.ID, overQuota.ID)
	if done.Status != StatusCompleted || done.Engine != EngineYtDlp || done.Filename != "demo_clip.mp4" {
		t.Fatalf("unexpected completed ytdlp task: %+v", done)
	}
	publishedPath := filepath.Join(volume, filepath.FromSlash(locationPath), "demo_clip.mp4")
	gotBytes, err := os.ReadFile(publishedPath)
	if err != nil || string(gotBytes) != "fake-mp4-video-payload-1234567890" {
		t.Fatalf("published video mismatch: %q %v", gotBytes, err)
	}
	meter, err := accounts.StorageMeter(session, member.ID)
	if err != nil || meter.UsedBytes != int64(len(gotBytes)) || meter.ReservedBytes != 0 {
		t.Fatalf("quota meter mismatch: %+v %v", meter, err)
	}
	if len(publishedEvents) != 1 {
		t.Fatalf("expected media refresh callback once, got %v", publishedEvents)
	}

	// Pause is rejected on yt-dlp tasks, while cancel kills the running subprocess.
	slowTask, err := m.CreateWithEngine(owner.ID, EngineYtDlp, "https://example.com/slow", locationPath, 0, EngineOptions{})
	if err != nil {
		t.Fatal(err)
	}
	waitForTaskRunning(t, m, owner.ID, slowTask.ID)
	if _, err := m.Action(owner.ID, slowTask.ID, "pause"); !errors.Is(err, ErrInput) {
		t.Fatalf("expected ErrInput on pause for ytdlp, got %v", err)
	}
	cancelled, err := m.Cancel(owner.ID, slowTask.ID)
	if err != nil || cancelled.Status != StatusCancelled {
		t.Fatalf("cancel ytdlp failed: %+v %v", cancelled, err)
	}
}

func TestWebArchiveEndToEndWithoutAria2AndSSRFBlockedByDefault(t *testing.T) {
	data, volume, reg, accounts, owner, member, session, root, locationPath := setupScopedRegistryEnv(t)

	img := image.NewRGBA(image.Rect(0, 0, 1, 1))
	img.Set(0, 0, color.RGBA{R: 10, G: 120, B: 220, A: 255})
	var pngBuf bytes.Buffer
	if err := png.Encode(&pngBuf, img); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/post":
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = io.WriteString(w, `<html><head><title>Offline Guide</title></head><body><article><p>Hello Archive</p><script>bad()</script><img src="/pic.png" alt="cover"></article></body></html>`)
		case "/pic.png":
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write(pngBuf.Bytes())
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	// 1. Default production config (WebArchiveOptions == nil) MUST block loopback SSRF.
	strictMgr, err := New(Options{
		DataDir:   data,
		Publisher: NewRegistryPublisher(reg, accounts),
		CanImport: func(int64, string) bool { return true },
	})
	if err != nil {
		t.Fatal(err)
	}
	blockedTask, err := strictMgr.CreateWithEngine(owner.ID, EngineWebArchive, srv.URL+"/post", locationPath, 0, EngineOptions{})
	if err != nil {
		t.Fatalf("create blocked webarchive task: %v", err)
	}
	blockedDone := waitForTaskTerminal(t, strictMgr, owner.ID, blockedTask.ID)
	if blockedDone.Status != StatusFailed || blockedDone.Error != webarchive.ErrBlockedAddress.Error() {
		t.Fatalf("expected SSRF block, got %+v", blockedDone)
	}
	_ = strictMgr.Close()

	// 2. With test AllowHosts, webarchive succeeds without aria2c and charges quota.
	if err := accounts.SetUserStorageRootQuota(session, member.ID, root.ID, root.Generation, 1<<20); err != nil {
		t.Fatal(err)
	}
	m, err := New(Options{
		DataDir:           data,
		Publisher:         NewRegistryPublisher(reg, accounts),
		CanImport:         func(int64, string) bool { return true },
		WebArchiveOptions: &webarchive.Options{AllowHosts: []string{"127.0.0.1", "::1"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()

	task, err := m.CreateWithEngine(owner.ID, EngineWebArchive, srv.URL+"/post", locationPath, 0, EngineOptions{})
	if err != nil {
		t.Fatalf("create webarchive task: %v", err)
	}
	done := waitForTaskTerminal(t, m, owner.ID, task.ID)
	if done.Status != StatusCompleted || done.Engine != EngineWebArchive || done.Filename != "Offline Guide.html" {
		t.Fatalf("unexpected webarchive task result: %+v", done)
	}

	savedPath := filepath.Join(volume, filepath.FromSlash(locationPath), "Offline Guide.html")
	content, err := os.ReadFile(savedPath)
	if err != nil {
		t.Fatalf("archived html missing: %v", err)
	}
	doc := string(content)
	if !strings.Contains(doc, "Hello Archive") || !strings.Contains(doc, "data:image/png;base64,") || strings.Contains(doc, "<script") {
		t.Fatalf("unexpected archived html content: %s", doc)
	}
	meter, err := accounts.StorageMeter(session, member.ID)
	if err != nil || meter.UsedBytes != int64(len(content)) {
		t.Fatalf("webarchive quota not charged: %+v %v", meter, err)
	}
}
