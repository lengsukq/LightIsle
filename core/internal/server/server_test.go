package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthAndHeaders(t *testing.T) {
	req := httptest.NewRequest("GET", "/api/v2/health", nil)
	rec := httptest.NewRecorder()
	New("", nil, nil).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status: %d", rec.Code)
	}
	if rec.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Fatal("nosniff missing")
	}
	var obj map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &obj); err != nil {
		t.Fatal(err)
	}
	if obj["platform"] != "darwin/arm64" {
		t.Fatalf("unexpected platform: %v", obj["platform"])
	}
}
func TestMethodAndMissingAssets(t *testing.T) {
	h := New("", nil, nil)
	w := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/api/v2/health", nil)
	req.Header.Set("X-LightIsle-Request", "1")
	h.ServeHTTP(w, req)
	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST health: %d", w.Code)
	}
	w = httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/", nil))
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("missing web status: %d", w.Code)
	}
}
func TestSystem(t *testing.T) {
	w := httptest.NewRecorder()
	New("", nil, nil).ServeHTTP(w, httptest.NewRequest("GET", "/api/v2/system", nil))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("unprotected metrics status %d: %s", w.Code, w.Body.String())
	}
}
