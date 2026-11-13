package server

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func BenchmarkServeCachedJPEG_304(b *testing.B) {
	key := strings.Repeat("a1b2c3d4", 8) // 64 hex chars
	cachePath := filepath.Join(b.TempDir(), key+".jpg")
	if err := os.WriteFile(cachePath, []byte("fake-jpeg-payload-bytes"), 0600); err != nil {
		b.Fatal(err)
	}
	f, err := os.Open(cachePath)
	if err != nil {
		b.Fatal(err)
	}
	defer f.Close()
	modTime := time.Unix(1700000000, 0)
	etag := `"` + key + `"`

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		req := httptest.NewRequest(http.MethodGet, "/api/v2/photos/1/thumbnail", nil)
		req.Header.Set("If-None-Match", etag)
		rec := httptest.NewRecorder()
		serveCachedJPEG(rec, req, "thumbnail.jpg", modTime, f)
		if rec.Code != http.StatusNotModified {
			b.Fatalf("status=%d, want 304", rec.Code)
		}
	}
}

func TestStaticAssetsAndCachedMediaETag304(t *testing.T) {
	webDir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(webDir, "assets"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(webDir, "index.html"), []byte("<!doctype html><html><body>LightIsle</body></html>"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(webDir, "assets", "index-D8x9k2.js"), []byte("console.log('lightisle');"), 0600); err != nil {
		t.Fatal(err)
	}

	api := &API{webRoot: webDir}
	handler := securityHeaders(http.HandlerFunc(api.static))

	// 1. Hashed Vite bundle under /assets/* gets immutable caching + ETag + 304.
	reqAsset := httptest.NewRequest(http.MethodGet, "/assets/index-D8x9k2.js", nil)
	recAsset := httptest.NewRecorder()
	handler.ServeHTTP(recAsset, reqAsset)
	if recAsset.Code != http.StatusOK {
		t.Fatalf("GET /assets/index-D8x9k2.js status=%d, want 200", recAsset.Code)
	}
	if cc := recAsset.Header().Get("Cache-Control"); cc != "public, max-age=31536000, immutable" {
		t.Fatalf("hashed asset Cache-Control=%q, want immutable", cc)
	}
	assetETag := recAsset.Header().Get("ETag")
	if assetETag == "" {
		t.Fatal("expected non-empty ETag on /assets/index-D8x9k2.js")
	}

	reqAsset304 := httptest.NewRequest(http.MethodGet, "/assets/index-D8x9k2.js", nil)
	reqAsset304.Header.Set("If-None-Match", assetETag)
	recAsset304 := httptest.NewRecorder()
	handler.ServeHTTP(recAsset304, reqAsset304)
	if recAsset304.Code != http.StatusNotModified || recAsset304.Body.Len() != 0 {
		t.Fatalf("conditional GET /assets/index-D8x9k2.js status=%d len=%d, want 304 empty", recAsset304.Code, recAsset304.Body.Len())
	}

	// 2. Entry index.html gets Cache-Control: no-cache + ETag + 304 so deploys take effect immediately.
	reqIndex := httptest.NewRequest(http.MethodGet, "/", nil)
	recIndex := httptest.NewRecorder()
	handler.ServeHTTP(recIndex, reqIndex)
	if recIndex.Code != http.StatusOK {
		t.Fatalf("GET / status=%d, want 200", recIndex.Code)
	}
	if cc := recIndex.Header().Get("Cache-Control"); cc != "no-cache" {
		t.Fatalf("index.html Cache-Control=%q, want no-cache", cc)
	}
	indexETag := recIndex.Header().Get("ETag")
	if indexETag == "" {
		t.Fatal("expected non-empty ETag on /")
	}

	reqIndex304 := httptest.NewRequest(http.MethodGet, "/", nil)
	reqIndex304.Header.Set("If-None-Match", indexETag)
	recIndex304 := httptest.NewRecorder()
	handler.ServeHTTP(recIndex304, reqIndex304)
	if recIndex304.Code != http.StatusNotModified || recIndex304.Body.Len() != 0 {
		t.Fatalf("conditional GET / status=%d len=%d, want 304 empty", recIndex304.Code, recIndex304.Body.Len())
	}
}
