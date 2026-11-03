package server

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func TestNetworkTestAuthenticatedInMemoryAndBounded(t *testing.T) {
	store, err := auth.Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "long-enough-admin-password"); err != nil {
		t.Fatal(err)
	}
	admin, err := store.Login("owner", "long-enough-admin-password")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateUser(admin, "member", "member-password-12345", auth.RoleMember); err != nil {
		t.Fatal(err)
	}
	member, err := store.Login("member", "member-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	h := New("", store, nil)
	call := func(method, path string, body []byte, login string) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, path, bytes.NewReader(body))
		if login != "" {
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: login})
		}
		if method == http.MethodPost {
			r.Header.Set("Content-Type", "application/octet-stream")
			r.Header.Set("X-LightIsle-Request", "1")
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}

	for _, endpoint := range []struct {
		method, path string
		body         []byte
	}{
		{"GET", "/api/v2/network-test/ping", nil},
		{"GET", "/api/v2/network-test/download?bytes=999", nil},
		{"POST", "/api/v2/network-test/upload", []byte("abc")},
	} {
		if w := call(endpoint.method, endpoint.path, endpoint.body, ""); w.Code != http.StatusUnauthorized {
			t.Fatalf("%s %s unprotected: %d", endpoint.method, endpoint.path, w.Code)
		}
	}
	if w := call("GET", "/api/v2/network-test/ping", nil, member); w.Code != http.StatusOK {
		t.Fatalf("member ping status: %d %s", w.Code, w.Body.String())
	} else {
		var reading struct {
			OK                bool  `json:"ok"`
			CoreUptimeSeconds int64 `json:"coreUptimeSeconds"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &reading); err != nil || !reading.OK || reading.CoreUptimeSeconds < 0 {
			t.Fatalf("invalid Core process uptime: %+v, %v", reading, err)
		}
	}
	w := call("GET", "/api/v2/network-test/download?bytes=131071", nil, member)
	if w.Code != http.StatusOK || w.Body.Len() != 131071 {
		t.Fatalf("download: %d, bytes=%d", w.Code, w.Body.Len())
	}
	if w.Header().Get("Cache-Control") != "private, no-store, no-transform" {
		t.Fatal("download should not be cached or modified by proxy")
	}
	if bytes.Equal(w.Body.Bytes()[:128], make([]byte, 128)) {
		t.Fatal("expected nonzero diagnostic data")
	}
	for _, size := range []string{"-1", "0", "16777217", "invalid"} {
		w := call("GET", "/api/v2/network-test/download?bytes="+size, nil, member)
		if w.Code != http.StatusBadRequest {
			t.Fatalf("download size %q allowed: %d", size, w.Code)
		}
	}
	w = call("POST", "/api/v2/network-test/upload", bytes.Repeat([]byte{0x4a}, 200001), member)
	if w.Code != http.StatusOK {
		t.Fatalf("upload: %d %s", w.Code, w.Body.String())
	}
	var result map[string]int
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil || result["receivedBytes"] != 200001 {
		t.Fatalf("upload receipt: %v, err=%v", result, err)
	}
	if w := call("POST", "/api/v2/network-test/upload", nil, member); w.Code != http.StatusBadRequest {
		t.Fatalf("empty upload status=%d", w.Code)
	}
	if w := call("POST", "/api/v2/network-test/upload", bytes.Repeat([]byte{0xaa}, maxNetworkTestBytes+1), member); w.Code != http.StatusBadRequest {
		t.Fatalf("oversized upload status=%d", w.Code)
	}
	for i := 0; i < cap(networkTestSlots); i++ {
		networkTestSlots <- struct{}{}
	}
	w = call("GET", "/api/v2/network-test/download?bytes=100", nil, member)
	for i := 0; i < cap(networkTestSlots); i++ {
		<-networkTestSlots
	}
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("concurrent downloads must be bounded: %d", w.Code)
	}
}

func TestNetworkTestSessionBandwidthBudget(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/api/v2/network-test/download", nil)
	r.AddCookie(&http.Cookie{Name: sessionCookie, Value: "separate-rate-limit-test-session"})
	key := sha256.Sum256([]byte(token(r)))
	t.Cleanup(func() {
		networkTestBudgets.Lock()
		delete(networkTestBudgets.entries, key)
		networkTestBudgets.Unlock()
	})
	for i := 0; i < networkTestBudgetBytes/maxNetworkTestBytes; i++ {
		w := httptest.NewRecorder()
		if !networkTestAllowBytes(w, r, maxNetworkTestBytes) {
			t.Fatalf("normal diagnostic attempt %d rejected: %d", i, w.Code)
		}
	}
	w := httptest.NewRecorder()
	if networkTestAllowBytes(w, r, 1) || w.Code != http.StatusTooManyRequests {
		t.Fatalf("expected session bandwidth budget rejection, status=%d", w.Code)
	}
	if w.Header().Get("Retry-After") == "" {
		t.Fatal("throttled client needs a retry hint")
	}
	networkTestBudgets.Lock()
	entry := networkTestBudgets.entries[key]
	entry.start = entry.start.Add(-6 * time.Minute)
	networkTestBudgets.entries[key] = entry
	networkTestBudgets.Unlock()
	w = httptest.NewRecorder()
	if !networkTestAllowBytes(w, r, 1024) {
		t.Fatal("expired bandwidth window must allow a new measurement")
	}
}
