package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSingleRootUnknownAPIDoesNotFallBackToSPA(t *testing.T) {
	web := t.TempDir()
	const index = "<!doctype html><title>LightIsle fixture</title><div id=app></div>"
	if err := os.WriteFile(filepath.Join(web, "index.html"), []byte(index), 0600); err != nil {
		t.Fatal(err)
	}
	handler := New(web, nil, nil)
	for _, path := range []string{"/api/v2/roots", "/api/v1/does-not-exist", "/api/", "/api"} {
		t.Run(path, func(t *testing.T) {
			res := httptest.NewRecorder()
			handler.ServeHTTP(res, httptest.NewRequest(http.MethodGet, path, nil))
			if res.Code != http.StatusNotFound || !strings.HasPrefix(res.Header().Get("Content-Type"), "application/json") {
				t.Fatalf("unknown API returned %d %q: %s", res.Code, res.Header().Get("Content-Type"), res.Body.String())
			}
			var body map[string]string
			if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil || body["error"] != "api_not_found" {
				t.Fatalf("unknown API must return a stable JSON error: %v %s", err, res.Body.String())
			}
		})
	}
	for _, path := range []string{"/", "/photos", "/cinema/123"} {
		res := httptest.NewRecorder()
		handler.ServeHTTP(res, httptest.NewRequest(http.MethodGet, path, nil))
		if res.Code != http.StatusOK || res.Body.String() != index {
			t.Fatalf("SPA route %s no longer works: %d %s", path, res.Code, res.Body.String())
		}
	}
}

func TestUnknownAPIIsJSONEvenWithoutWebAssets(t *testing.T) {
	res := httptest.NewRecorder()
	New("", nil, nil).ServeHTTP(res, httptest.NewRequest(http.MethodGet, "/api/v2/roots", nil))
	if res.Code != http.StatusNotFound || !strings.Contains(res.Body.String(), "api_not_found") {
		t.Fatalf("API capability probe depends on Web assets: %d %s", res.Code, res.Body.String())
	}
}
