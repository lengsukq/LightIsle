package apps

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestServeIconETagAnd304(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "", nil)
	defer mgr.Close()
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v2/apps/network-pulse/icon", nil)
	rec := httptest.NewRecorder()
	mgr.ServeIcon(rec, req, "network-pulse")
	if rec.Code != http.StatusOK {
		t.Fatalf("ServeIcon status=%d, want 200", rec.Code)
	}
	etag := rec.Header().Get("ETag")
	if etag == "" {
		t.Fatal("expected ETag header on ServeIcon")
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "private, max-age=300, stale-while-revalidate=86400" {
		t.Fatalf("ServeIcon Cache-Control=%q", cc)
	}

	req304 := httptest.NewRequest(http.MethodGet, "/api/v2/apps/network-pulse/icon", nil)
	req304.Header.Set("If-None-Match", etag)
	rec304 := httptest.NewRecorder()
	mgr.ServeIcon(rec304, req304, "network-pulse")
	if rec304.Code != http.StatusNotModified || rec304.Body.Len() != 0 {
		t.Fatalf("ServeIcon conditional status=%d len=%d, want 304 empty", rec304.Code, rec304.Body.Len())
	}
}
