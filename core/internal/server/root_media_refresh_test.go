package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/roots"
)

func TestMediaKindForPath(t *testing.T) {
	for _, tc := range []struct{ path, want string }{
		{"图库/2026/照片.heic", "gallery"},
		{"photos/DCIM/a.jpeg", "gallery"},
		{"Users/u5/photos/my-photo.heic", "gallery"},
		{"Users/u5/videos/my-video.mp4", "cinema"},
		{"影视/剧集/S01E01.mkv", "cinema"},
		{"videos/one.mkv", "cinema"},
		{"Users/u5/files/text.txt", ""},
		{"Users/u5/other/anything.mov", ""},
		{"docs/readme.txt", ""},
		{"random/photos/media.jpg", "gallery"},
		{"家庭/2026/生日.jpg", "gallery"},
		{"家庭/婚礼.HEIC", "gallery"},
		{"Movies/Film.MKV", "cinema"},
		{"Users/u5/files/camera.mp4", "cinema"},
		{".lightisle-config/movie.mp4", ""},
		{"docs/pictures.zip", ""},
		{"", ""},
	} {
		if got := mediaKindForPath(tc.path); got != tc.want {
			t.Errorf("mediaKindForPath(%q) = %q, want %q", tc.path, got, tc.want)
		}
	}
}

func TestMediaRefreshRetriesAfterExistingScan(t *testing.T) {
	f := newRootRoutingFixture(t)
	if err := os.WriteFile(filepath.Join(f.pathA, "new.jpg"), []byte("synthetic photo"), 0600); err != nil {
		t.Fatal(err)
	}
	lease, err := f.server.AcquireRootServices(context.Background(), f.rootA.ID)
	if err != nil {
		t.Fatal(err)
	}
	f.server.mu.Lock()
	runtime := f.server.runtimes[f.rootA.ID]
	f.server.mu.Unlock()
	runtime.scanMu.Lock()
	runtime.scans["gallery"] = &roots.Lease{}
	runtime.scanMu.Unlock()
	lease.Close()

	f.server.refreshOneRootMedia(f.rootA.ID, "gallery")
	key := f.rootA.ID + ":gallery"
	f.server.mu.Lock()
	timer := f.server.mediaRefreshTimers[key]
	f.server.mu.Unlock()
	if timer == nil {
		t.Fatal("busy scan dropped the pending refresh")
	}
	runtime.scanMu.Lock()
	delete(runtime.scans, "gallery")
	runtime.scanMu.Unlock()
	timer.Reset(10 * time.Millisecond)
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		items, _, err := runtime.services.Gallery.List(0, 20, 0, false)
		if err == nil && len(items) == 1 && items[0].Path == "new.jpg" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("pending refresh did not index the file after the scan became idle")
}

func TestMediaRefreshCoalescesDirectoriesAndKeepsBusyScope(t *testing.T) {
	f := newRootRoutingFixture(t)
	f.server.QueueMediaRefresh(f.rootA.ID, "Users/u1/photos/旅行/a.jpg")
	f.server.QueueMediaRefresh(f.rootA.ID, "Users/u1/photos/家庭/b.jpg")
	key := f.rootA.ID + ":gallery"
	f.server.mu.Lock()
	scope := f.server.mediaRefreshScopes[key]
	_, travel := scope["Users/u1/photos/旅行"]
	_, family := scope["Users/u1/photos/家庭"]
	count := len(scope)
	timer := f.server.mediaRefreshTimers[key]
	f.server.mu.Unlock()
	if timer == nil || count != 2 || !travel || !family {
		t.Fatalf("photo changes not coalesced by directory: count=%d travel=%v family=%v", count, travel, family)
	}
	lease, err := f.server.AcquireRootServices(context.Background(), f.rootA.ID)
	if err != nil {
		t.Fatal(err)
	}
	f.server.mu.Lock()
	runtime := f.server.runtimes[f.rootA.ID]
	f.server.mu.Unlock()
	runtime.scanMu.Lock()
	runtime.scans["gallery"] = &roots.Lease{}
	runtime.scanMu.Unlock()
	lease.Close()
	f.server.refreshOneRootMediaScope(f.rootA.ID, "gallery", 0, []string{"Users/u1/photos/另一个"})
	f.server.mu.Lock()
	_, retryKept := f.server.mediaRefreshScopes[key]["Users/u1/photos/另一个"]
	f.server.mu.Unlock()
	runtime.scanMu.Lock()
	delete(runtime.scans, "gallery")
	runtime.scanMu.Unlock()
	if !retryKept {
		t.Fatal("busy scan lost the affected directory")
	}
}

func TestNativeMediaRefreshRejectsAnOldRootGeneration(t *testing.T) {
	f := newRootRoutingFixture(t)
	if err := os.WriteFile(filepath.Join(f.pathA, "new.jpg"), []byte("synthetic photo"), 0600); err != nil {
		t.Fatal(err)
	}
	f.server.refreshOneRootMediaGeneration(f.rootA.ID, "gallery", f.rootA.Generation+1)
	lease, err := f.server.AcquireRootServices(context.Background(), f.rootA.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	if status := lease.Services.Gallery.Status(); status.Running || status.LastDone != 0 {
		t.Fatalf("stale notification started a scan: %+v", status)
	}
}

func TestDAVPublicationQueuesMediaRefreshOnlyAfterSuccess(t *testing.T) {
	f := newRootRoutingFixture(t)
	_, password, err := f.accounts.CreateDAVCredential(f.admin, "refresh-test")
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPut, "/dav/photo.jpg", strings.NewReader("photo"))
	request.SetBasicAuth("owner", password)
	response := httptest.NewRecorder()
	f.server.ServeHTTP(response, request)
	if response.Code < 200 || response.Code >= 300 {
		t.Fatalf("DAV write failed: %d %s", response.Code, response.Body.String())
	}
	f.server.mu.Lock()
	for _, kind := range []string{"gallery", "cinema"} {
		key := f.rootA.ID + ":" + kind
		if f.server.mediaRefreshTimers[key] == nil {
			f.server.mu.Unlock()
			t.Fatalf("DAV write did not queue %s refresh", kind)
		}
		f.server.mediaRefreshTimers[key].Stop()
		delete(f.server.mediaRefreshTimers, key)
	}
	f.server.mu.Unlock()
	denied := httptest.NewRequest(http.MethodPut, "/dav/denied.jpg", strings.NewReader("photo"))
	denied.SetBasicAuth("owner", "incorrect")
	response = httptest.NewRecorder()
	f.server.ServeHTTP(response, denied)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("unexpected unauthorized DAV response: %d", response.Code)
	}
	f.server.mu.Lock()
	defer f.server.mu.Unlock()
	if len(f.server.mediaRefreshTimers) != 0 {
		t.Fatal("unauthorized DAV write queued a refresh")
	}
}

func TestDefaultTaskRoutesUseCurrentVerifiedRoot(t *testing.T) {
	f := newRootRoutingFixture(t)
	for _, root := range []struct {
		id         string
		generation uint64
	}{
		{f.rootA.ID, f.rootA.Generation},
		{f.rootB.ID, f.rootB.Generation},
	} {
		if err := f.registry.SetDefault(t.Context(), root.id, root.generation); err != nil {
			t.Fatal(err)
		}
		// The fixture deliberately has no host-wide journal, only per-root
		// journals. This verifies that host history is NOT accidentally
		// replaced by whichever root was selected as default.
		if r := f.call(f.admin, "GET", "/api/v2/tasks", ""); r.Code != 200 {
			t.Fatalf("host task list lost after root switch: %d %s", r.Code, r.Body.String())
		}
		if r := f.call(f.admin, "GET", "/api/v2/tasks/history", ""); r.Code != 503 {
			t.Fatalf("host task history was silently replaced by root %s: %d %s", root.id, r.Code, r.Body.String())
		}
		// But default-root media task controls must reach the live root
		// instead of the disabled single-root global gallery.
		if r := f.call(f.admin, "POST", "/api/v2/tasks/gallery/retry", ""); r.Code != 202 {
			t.Fatalf("media retry did not route to root %s: %d %s", root.id, r.Code, r.Body.String())
		}
		missing := f.call(f.member, "POST", "/api/v2/tasks/gallery/retry", "")
		if missing.Code != 403 && missing.Code != 404 {
			t.Fatalf("member started administrator task on %s: %d %s", root.id, missing.Code, missing.Body.String())
		}
	}
}
