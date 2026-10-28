package maptiles

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type transportFunc func(*http.Request) (*http.Response, error)

func (fn transportFunc) RoundTrip(req *http.Request) (*http.Response, error) { return fn(req) }

func TestKeyValidationAndClear(t *testing.T) {
	s := New()
	for _, key := range []string{"", "short", "a&tk=injected", "ab cdefgh", strings.Repeat("a", 129)} {
		if s.Set(key) == nil {
			t.Fatalf("accepted invalid map key")
		}
	}
	if s.Configured() {
		t.Fatal("invalid keys must not configure service")
	}
	if err := s.Set("safe-test-key-1234"); err != nil {
		t.Fatal(err)
	}
	if !s.Configured() {
		t.Fatal("expected configured")
	}
	s.Clear()
	if s.Configured() {
		t.Fatal("clear still configured")
	}
}

func TestTileProxyFixedHostAndNoSecretLeak(t *testing.T) {
	s := New()
	if err := s.Set("safe-test-key-1234"); err != nil {
		t.Fatal(err)
	}
	called := 0
	s.SetHTTPClientForTest(&http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		called++
		if r.URL.Scheme != "https" || r.URL.Host != "t0.tianditu.gov.cn" || r.URL.Path != "/vec_w/wmts" {
			t.Fatalf("unexpected remote destination: %s", r.URL.Redacted())
		}
		if want := "safe-test-key-1234"; r.URL.Query().Get("tk") != want {
			t.Fatal("missing key on upstream only")
		}
		if r.URL.Query().Get("TILEMATRIX") != "3" || r.URL.Query().Get("TILEROW") != "2" || r.URL.Query().Get("TILECOL") != "4" {
			t.Fatal("invalid tile coordinates")
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"image/png"}}, Body: io.NopCloser(bytes.NewReader([]byte("\x89PNG\r\n\x1a\n")))}, nil
	})})
	req := httptest.NewRequest("GET", "/api/v2/map/tiles/tianditu/vec/3/4/2", nil)
	response := httptest.NewRecorder()
	s.ServeTile(response, req, "vec", "3", "4", "2")
	if response.Code != 200 || called != 1 {
		t.Fatalf("proxy HTTP %d requests=%d", response.Code, called)
	}
	if strings.Contains(response.Body.String(), "safe-test-key-1234") {
		t.Fatal("secret leaked in response")
	}
	if strings.Contains(response.Header().Get("Content-Type"), "text/html") {
		t.Fatal("bad tile MIME")
	}
}

func TestTileProxyRejectsBadCoordinatesAndDoesNotForwardErrors(t *testing.T) {
	s := New()
	for _, tc := range []struct {
		layer, z, x, y string
		code           int
	}{
		{"img", "1", "0", "0", 400}, {"vec", "19", "0", "0", 400},
		{"vec", "3", "8", "0", 400}, {"vec", "3", "0", "7/evil", 400},
	} {
		w := httptest.NewRecorder()
		s.ServeTile(w, httptest.NewRequest("GET", "/", nil), tc.layer, tc.z, tc.x, tc.y)
		if w.Code != tc.code {
			t.Fatalf("%v: got %d", tc, w.Code)
		}
	}
	w := httptest.NewRecorder()
	s.ServeTile(w, httptest.NewRequest("GET", "/", nil), "vec", "3", "2", "4")
	if w.Code != 503 {
		t.Fatalf("unconfigured: %d", w.Code)
	}
	if err := s.Set("safe-test-key-1234"); err != nil {
		t.Fatal(err)
	}
	s.SetHTTPClientForTest(&http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 403, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(`{"secret":"safe-test-key-1234"}`))}, nil
	})})
	w = httptest.NewRecorder()
	s.ServeTile(w, httptest.NewRequest("GET", "/", nil), "vec", "3", "2", "4")
	if w.Code != 502 || strings.Contains(w.Body.String(), "safe-test-key-1234") {
		t.Fatalf("upstream response leaked: %d", w.Code)
	}
}
