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
	for _, path := range []string{"/api/v2/roots", "/api/v2/does-not-exist", "/api/", "/api"} {
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

func TestV2OnlyRoutingDoesNotRetainLegacyAPIAliases(t *testing.T) {
	for name, handler := range map[string]http.Handler{
		"single-root": New("", nil, nil),
		"multi-root":  NewWithRoots("", nil, nil, nil, nil, nil, nil, nil),
	} {
		t.Run(name, func(t *testing.T) {
			for _, path := range []string{"/api/v2/health", "/api/v2/system"} {
				res := httptest.NewRecorder()
				handler.ServeHTTP(res, httptest.NewRequest(http.MethodGet, path, nil))
				if res.Code == http.StatusNotFound {
					t.Fatalf("v2 business API %s was swallowed by the root router", path)
				}
			}
			for _, path := range []string{"/api/v1/health", "/api/v1/files", "/api/v1/auth/login", "/api/v1/me/storage"} {
				res := httptest.NewRecorder()
				handler.ServeHTTP(res, httptest.NewRequest(http.MethodGet, path, nil))
				if res.Code != http.StatusNotFound {
					t.Fatalf("deleted legacy API %s remained callable: %d", path, res.Code)
				}
			}
		})
	}
}

func TestUnknownAPIIsJSONEvenWithoutWebAssets(t *testing.T) {
	res := httptest.NewRecorder()
	New("", nil, nil).ServeHTTP(res, httptest.NewRequest(http.MethodGet, "/api/v2/roots", nil))
	if res.Code != http.StatusNotFound || !strings.Contains(res.Body.String(), "api_not_found") {
		t.Fatalf("API capability probe depends on Web assets: %d %s", res.Code, res.Body.String())
	}
}
