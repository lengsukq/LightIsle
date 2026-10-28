package server

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/maptiles"
)

func TestMapStatusRequiresLoginAndNeverReturnsKey(t *testing.T) {
	dataDir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "valid-owner-password"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "valid-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	shared, err := files.NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer shared.Close()
	maptiles.Default.Clear()
	t.Cleanup(maptiles.Default.Clear)
	handler := New("", accounts, shared)
	request := func(path string, signedIn bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, path, nil)
		if signedIn {
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: admin})
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	for _, path := range []string{"/api/v2/map/status", "/api/v2/map/tiles/tianditu/vec/4/7/8"} {
		if w := request(path, false); w.Code != http.StatusUnauthorized {
			t.Fatalf("anonymous map %s: HTTP %d", path, w.Code)
		}
	}
	if w := request("/api/v2/map/status", true); w.Code != 200 || !strings.Contains(w.Body.String(), `"tiandituConfigured":false`) {
		t.Fatalf("before setup: %d %s", w.Code, w.Body.String())
	}
	if err := maptiles.Default.Set("safe-test-key-1234"); err != nil {
		t.Fatal(err)
	}
	if w := request("/api/v2/map/status", true); w.Code != 200 || !strings.Contains(w.Body.String(), `"tiandituConfigured":true`) || strings.Contains(w.Body.String(), "safe-test-key-1234") {
		t.Fatalf("config leaked: %d %s", w.Code, w.Body.String())
	}
	if w := request("/api/v2/map/tiles/tianditu/custom/4/7/8", true); w.Code != 400 {
		t.Fatalf("invalid layer: HTTP %d", w.Code)
	}
}
