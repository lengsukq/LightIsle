package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

type posterAPIWorker struct {
	mu          sync.Mutex
	posterCalls int
}

func (w *posterAPIWorker) Probe(_ context.Context, _ *os.File, name string) (mediaworker.Metadata, error) {
	if filepath.Ext(name) == ".mkv" {
		return mediaworker.Metadata{}, mediaworker.ErrUnsupported
	}
	return mediaworker.Metadata{Version: 1, Status: "ok", Kind: "video", MIME: "video/mp4", Container: "MPEG-4",
		VideoCodec: "h264", AudioCodec: "aac", DurationSeconds: 3, Width: 80, Height: 48}, nil
}

func (w *posterAPIWorker) Poster(_ context.Context, _ *os.File, _ string, output string) (mediaworker.Metadata, error) {
	w.mu.Lock()
	w.posterCalls++
	w.mu.Unlock()
	if err := os.WriteFile(output, []byte{0xff, 0xd8, 0xff, 1, 0xff, 0xd9}, 0600); err != nil {
		return mediaworker.Metadata{}, err
	}
	return mediaworker.Metadata{Version: 1, Status: "ok", Kind: "video", Width: 80, Height: 48}, nil
}

func (w *posterAPIWorker) calls() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.posterCalls
}

func waitMediaLibraries(t *testing.T, photos *gallery.Library, films *cinema.Library) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if !photos.Status().Running && !films.Status().Running {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if photos.Status().Running || films.Status().Running || photos.Status().LastError != "" || films.Status().LastError != "" {
		t.Fatalf("media scan failed: gallery=%+v cinema=%+v", photos.Status(), films.Status())
	}
}

func TestCinemaPosterRealEndpointUsesSharedCacheAndChecksSource(t *testing.T) {
	dataDir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "valid-owner-password"); err != nil {
		t.Fatal(err)
	}
	adminToken, err := accounts.Login("owner", "valid-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := accounts.CreateUser(adminToken, "member", "valid-member-password", auth.RoleMember); err != nil {
		t.Fatal(err)
	}
	memberToken, err := accounts.Login("member", "valid-member-password")
	if err != nil {
		t.Fatal(err)
	}

	shared, err := files.NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer shared.Close()
	share, _ := shared.State()
	filmPath := filepath.Join(share, "clip.mp4")
	if err := os.WriteFile(filmPath, []byte("video source bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	photos, err := gallery.Open(dataDir, shared)
	if err != nil {
		t.Fatal(err)
	}
	defer photos.Close()
	films, err := cinema.Open(dataDir, shared)
	if err != nil {
		t.Fatal(err)
	}
	defer films.Close()
	worker := &posterAPIWorker{}
	photos.SetMediaWorker(worker)
	films.SetMediaWorker(worker)
	if err := photos.StartScan(); err != nil {
		t.Fatal(err)
	}
	if err := films.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitMediaLibraries(t, photos, films)
	items, _, err := films.List(1, "", "", 20, 0)
	if err != nil || len(items) != 1 {
		t.Fatalf("film index = %+v, %v", items, err)
	}
	filmID := items[0].ID
	handler := NewWithCinema("", accounts, shared, photos, films)
	call := func(method, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "/api/v1/cinema/"+strconv.FormatInt(filmID, 10)+"/poster", nil)
		r.Header.Set("X-LightIsle-Request", "1")
		r.AddCookie(&http.Cookie{Name: sessionCookie, Value: token})
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	denied := call(http.MethodGet, memberToken)
	if denied.Code != http.StatusForbidden {
		t.Fatalf("ungranted poster access = %d %s", denied.Code, denied.Body.String())
	}
	first := call(http.MethodGet, adminToken)
	if first.Code != http.StatusOK || first.Header().Get("Content-Type") != "image/jpeg" || first.Body.Len() == 0 {
		t.Fatalf("poster response = %d %s %s", first.Code, first.Header().Get("Content-Type"), first.Body.String())
	}
	second := call(http.MethodGet, adminToken)
	if second.Code != http.StatusOK || worker.calls() != 1 {
		t.Fatalf("shared thumbnail cache missed: status=%d poster calls=%d", second.Code, worker.calls())
	}
	head := call(http.MethodHead, adminToken)
	if head.Code != http.StatusOK || head.Body.Len() != 0 {
		t.Fatalf("HEAD poster = %d, body=%d", head.Code, head.Body.Len())
	}

	if err := os.WriteFile(filmPath, []byte("replacement source is longer"), 0600); err != nil {
		t.Fatal(err)
	}
	changed := time.Now().Add(time.Second)
	if err := os.Chtimes(filmPath, changed, changed); err != nil {
		t.Fatal(err)
	}
	stale := call(http.MethodGet, adminToken)
	if stale.Code != http.StatusConflict {
		t.Fatalf("stale source poster response = %d %s", stale.Code, stale.Body.String())
	}
}

func TestCinemaPosterUnsupportedProbeDoesNotReturnPlaceholderAsReady(t *testing.T) {
	dataDir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "valid-owner-password"); err != nil {
		t.Fatal(err)
	}
	adminToken, err := accounts.Login("owner", "valid-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	shared, err := files.NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer shared.Close()
	share, _ := shared.State()
	if err := os.WriteFile(filepath.Join(share, "odd.mkv"), []byte("unsupported"), 0600); err != nil {
		t.Fatal(err)
	}
	photos, err := gallery.Open(dataDir, shared)
	if err != nil {
		t.Fatal(err)
	}
	defer photos.Close()
	films, err := cinema.Open(dataDir, shared)
	if err != nil {
		t.Fatal(err)
	}
	defer films.Close()
	worker := &posterAPIWorker{}
	photos.SetMediaWorker(worker)
	films.SetMediaWorker(worker)
	if err := films.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for films.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	items, _, err := films.List(1, "", "", 20, 0)
	if err != nil || len(items) != 1 || items[0].ProbeStatus != "unsupported" {
		t.Fatalf("unsupported scan result = %+v, %v", items, err)
	}
	handler := NewWithCinema("", accounts, shared, photos, films)
	r := httptest.NewRequest(http.MethodGet, "/api/v1/cinema/"+strconv.FormatInt(items[0].ID, 10)+"/poster", nil)
	r.Header.Set("X-LightIsle-Request", "1")
	r.AddCookie(&http.Cookie{Name: sessionCookie, Value: adminToken})
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != http.StatusUnsupportedMediaType || worker.calls() != 0 {
		t.Fatalf("unsupported poster response = %d, worker poster calls=%d", w.Code, worker.calls())
	}
}
