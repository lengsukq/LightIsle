package apps

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func setupKVTestServer(t *testing.T, mgr *Manager) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mgr.ServeApp(w, r, func(req *http.Request) (UserIdentity, bool) {
			switch req.Header.Get("X-Test-User") {
			case "admin":
				return UserIdentity{ID: 1, Username: "admin", Role: "admin"}, true
			case "member":
				return UserIdentity{ID: 2, Username: "alice", Role: "member"}, true
			case "outsider":
				return UserIdentity{ID: 99, Username: "eve", Role: "member"}, true
			default:
				return UserIdentity{}, false
			}
		})
	}))
}

func TestAppKVStoreCRUDLockingCSRFAndBackupRoundTrip(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "", nil)
	defer mgr.Close()
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}
	attachRepoStoreForTest(t, mgr)
	if _, err := mgr.InstallStorePlugin(context.Background(), "house-info", ""); err != nil {
		t.Fatalf("install house-info: %v", err)
	}
	if _, err := mgr.InstallStorePlugin(context.Background(), "weekly-menu", ""); err != nil {
		t.Fatalf("install weekly-menu: %v", err)
	}

	srv := setupKVTestServer(t, mgr)
	defer srv.Close()

	doReq := func(method, path, user, csrf, ifMatch, body string) *http.Response {
		t.Helper()
		var reader io.Reader
		if body != "" {
			reader = strings.NewReader(body)
		}
		req, err := http.NewRequest(method, srv.URL+path, reader)
		if err != nil {
			t.Fatal(err)
		}
		if user != "" {
			req.Header.Set("X-Test-User", user)
		}
		if csrf != "" {
			req.Header.Set("X-LightIsle-Request", csrf)
		}
		if ifMatch != "" {
			req.Header.Set("If-Match", ifMatch)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}

	// 1. Unauthenticated access rejected
	resp := doReq(http.MethodGet, "/apps/house-info/__lightisle_kv/state", "", "", "", "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 unauthenticated, got %d", resp.StatusCode)
	}

	// 2. Empty list and missing key 404
	resp = doReq(http.MethodGet, "/apps/house-info/__lightisle_kv", "member", "", "", "")
	if resp.StatusCode != http.StatusOK || resp.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("unexpected empty list status=%d cc=%q", resp.StatusCode, resp.Header.Get("Cache-Control"))
	}
	var listResp kvListResponse
	_ = json.NewDecoder(resp.Body).Decode(&listResp)
	resp.Body.Close()
	if listResp.Count != 0 || len(listResp.Keys) != 0 {
		t.Fatalf("expected 0 keys, got %+v", listResp)
	}

	resp = doReq(http.MethodGet, "/apps/house-info/__lightisle_kv/state", "member", "", "", "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404 for missing key, got %d", resp.StatusCode)
	}

	// 3. CSRF guard on PUT and DELETE
	resp = doReq(http.MethodPut, "/apps/house-info/__lightisle_kv/state", "member", "", "", `{"a":1}`)
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected 403 without CSRF header, got %d", resp.StatusCode)
	}

	// 4. Invalid JSON rejected
	resp = doReq(http.MethodPut, "/apps/house-info/__lightisle_kv/state", "member", "1", "", `{broken`)
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 invalid JSON, got %d", resp.StatusCode)
	}

	// 5. Invalid keys rejected (including traversal)
	for _, badKey := range []string{".hidden", "-bad", "a..b", "sub/key", strings.Repeat("a", 65)} {
		r := doReq(http.MethodPut, "/apps/house-info/__lightisle_kv/"+badKey, "member", "1", "", `{}`)
		r.Body.Close()
		if r.StatusCode != http.StatusBadRequest {
			t.Fatalf("expected 400 for bad key %q, got %d", badKey, r.StatusCode)
		}
	}

	// 6. Valid PUT state + _reminders
	resp = doReq(http.MethodPut, "/apps/house-info/__lightisle_kv/state", "member", "1", "", `[{"id":"1","title":"Wi-Fi","val":"home1234"}]`)
	etag1 := resp.Header.Get("ETag")
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || etag1 == "" || resp.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("unexpected PUT response status=%d etag=%q", resp.StatusCode, etag1)
	}

	resp = doReq(http.MethodPut, "/apps/house-info/__lightisle_kv/_reminders", "member", "1", "", `{"items":[{"id":"r1","title":"Test","dueDate":"2026-12-01","warnDays":7}]}`)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 for _reminders key, got %d", resp.StatusCode)
	}

	// 7. Cross-app isolation: weekly-menu cannot see house-info's state
	resp = doReq(http.MethodGet, "/apps/weekly-menu/__lightisle_kv/state", "member", "", "", "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404 cross-app isolation, got %d", resp.StatusCode)
	}

	// 8. GET returns stored JSON + matching ETag; If-None-Match returns 304
	resp = doReq(http.MethodGet, "/apps/house-info/__lightisle_kv/state", "member", "", "", "")
	gotBody, _ := io.ReadAll(resp.Body)
	gotETag := resp.Header.Get("ETag")
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || gotETag != etag1 || !strings.Contains(string(gotBody), "home1234") {
		t.Fatalf("unexpected GET status=%d etag=%q body=%s", resp.StatusCode, gotETag, string(gotBody))
	}

	req304, _ := http.NewRequest(http.MethodGet, srv.URL+"/apps/house-info/__lightisle_kv/state", nil)
	req304.Header.Set("X-Test-User", "member")
	req304.Header.Set("If-None-Match", etag1)
	resp304, err := http.DefaultClient.Do(req304)
	if err != nil {
		t.Fatal(err)
	}
	resp304.Body.Close()
	if resp304.StatusCode != http.StatusNotModified {
		t.Fatalf("expected 304 on If-None-Match, got %d", resp304.StatusCode)
	}

	// 9. Optimistic locking with If-Match and If-None-Match: *
	createIfAbsent := func(key, body string) *http.Response {
		req, _ := http.NewRequest(http.MethodPut, srv.URL+"/apps/house-info/__lightisle_kv/"+key, strings.NewReader(body))
		req.Header.Set("X-Test-User", "member")
		req.Header.Set("X-LightIsle-Request", "1")
		req.Header.Set("If-None-Match", "*")
		r, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	rInmConflict := createIfAbsent("state", `[{"id":"dup"}]`)
	var inmBody map[string]string
	_ = json.NewDecoder(rInmConflict.Body).Decode(&inmBody)
	inmETag := rInmConflict.Header.Get("ETag")
	rInmConflict.Body.Close()
	if rInmConflict.StatusCode != http.StatusPreconditionFailed || inmBody["etag"] != etag1 || inmETag != etag1 {
		t.Fatalf("expected 412 for If-None-Match: * on existing key, got status=%d body=%+v hdr=%q", rInmConflict.StatusCode, inmBody, inmETag)
	}
	rInmOK := createIfAbsent("brand_new", `{"created":true}`)
	rInmOK.Body.Close()
	if rInmOK.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 for If-None-Match: * on missing key, got %d", rInmOK.StatusCode)
	}

	resp = doReq(http.MethodPut, "/apps/house-info/__lightisle_kv/state", "member", "1", `"stale-etag"`, `[{"id":"2"}]`)
	var conflictBody map[string]string
	_ = json.NewDecoder(resp.Body).Decode(&conflictBody)
	conflictHdrETag := resp.Header.Get("ETag")
	resp.Body.Close()
	if resp.StatusCode != http.StatusPreconditionFailed || conflictBody["etag"] != etag1 || conflictHdrETag != etag1 {
		t.Fatalf("expected 412 with current etag %q, got status=%d body=%+v hdr=%q", etag1, resp.StatusCode, conflictBody, conflictHdrETag)
	}

	resp = doReq(http.MethodPut, "/apps/house-info/__lightisle_kv/state", "member", "1", etag1, `[{"id":"2","title":"宽带","val":"1000M"}]`)
	etag2 := resp.Header.Get("ETag")
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || etag2 == "" || etag2 == etag1 {
		t.Fatalf("expected 200 and new etag, got status=%d etag2=%q", resp.StatusCode, etag2)
	}

	// 10. ExportAppData + RestoreAppData preserves kv/*.json
	var archiveBuf bytes.Buffer
	if err := mgr.ExportAppData(context.Background(), "house-info", &archiveBuf); err != nil {
		t.Fatalf("ExportAppData failed: %v", err)
	}
	// Delete state key, verify 404, then restore from archive
	resp = doReq(http.MethodDelete, "/apps/house-info/__lightisle_kv/state", "member", "", "", "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected 403 DELETE without CSRF, got %d", resp.StatusCode)
	}
	resp = doReq(http.MethodDelete, "/apps/house-info/__lightisle_kv/state", "member", "1", `"wrong"`, "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusPreconditionFailed {
		t.Fatalf("expected 412 DELETE stale If-Match, got %d", resp.StatusCode)
	}
	resp = doReq(http.MethodDelete, "/apps/house-info/__lightisle_kv/state", "member", "1", etag2, "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 DELETE with matching If-Match, got %d", resp.StatusCode)
	}
	resp = doReq(http.MethodGet, "/apps/house-info/__lightisle_kv/state", "member", "", "", "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404 after delete, got %d", resp.StatusCode)
	}

	if err := mgr.RestoreAppData(context.Background(), "house-info", bytes.NewReader(archiveBuf.Bytes())); err != nil {
		t.Fatalf("RestoreAppData failed: %v", err)
	}
	resp = doReq(http.MethodGet, "/apps/house-info/__lightisle_kv/state", "member", "", "", "")
	restoredBody, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(restoredBody), "1000M") {
		t.Fatalf("expected restored KV payload, got status=%d body=%s", resp.StatusCode, string(restoredBody))
	}
}

func TestAppKVStoreQuotasSymlinkAndConcurrency(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "", nil)
	defer mgr.Close()
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}
	attachRepoStoreForTest(t, mgr)
	if _, err := mgr.InstallStorePlugin(context.Background(), "house-info", ""); err != nil {
		t.Fatal(err)
	}
	srv := setupKVTestServer(t, mgr)
	defer srv.Close()

	put := func(key, body string) *http.Response {
		req, _ := http.NewRequest(http.MethodPut, srv.URL+"/apps/house-info/__lightisle_kv/"+key, strings.NewReader(body))
		req.Header.Set("X-Test-User", "admin")
		req.Header.Set("X-LightIsle-Request", "1")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}

	// Single key > 512 KiB rejected
	oversized := `"` + strings.Repeat("x", maxKVValueBytes) + `"`
	resp := put("big", oversized)
	resp.Body.Close()
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413 for >512KiB value, got %d", resp.StatusCode)
	}

	// Symlink planted inside kv/ must be rejected
	kvDir := filepath.Join(dataDir, "plugin-data", "house-info", "kv")
	if err := os.MkdirAll(kvDir, 0700); err != nil {
		t.Fatal(err)
	}
	outsideFile := filepath.Join(t.TempDir(), "secret.json")
	_ = os.WriteFile(outsideFile, []byte(`{"secret":true}`), 0600)
	_ = os.Symlink(outsideFile, filepath.Join(kvDir, "escaped.json"))

	getReq, _ := http.NewRequest(http.MethodGet, srv.URL+"/apps/house-info/__lightisle_kv/escaped", nil)
	getReq.Header.Set("X-Test-User", "admin")
	getResp, err := http.DefaultClient.Do(getReq)
	if err != nil {
		t.Fatal(err)
	}
	getResp.Body.Close()
	if getResp.StatusCode == http.StatusOK {
		t.Fatalf("expected symlink read to be rejected, got 200")
	}
	_ = os.Remove(filepath.Join(kvDir, "escaped.json"))

	// Total size > 4 MiB rejected (9 keys x 500 KiB > 4 MiB)
	chunk := `"` + strings.Repeat("a", 500*1024) + `"`
	for i := 0; i < 8; i++ {
		r := put(fmt.Sprintf("chunk_%d", i), chunk)
		r.Body.Close()
		if r.StatusCode != http.StatusOK {
			t.Fatalf("expected chunk %d to succeed, got %d", i, r.StatusCode)
		}
	}
	rOver := put("chunk_overflow", chunk)
	rOver.Body.Close()
	if rOver.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413 when exceeding 4 MiB app total, got %d", rOver.StatusCode)
	}

	// Clean chunks and verify 64-key count limit
	for i := 0; i < 8; i++ {
		delReq, _ := http.NewRequest(http.MethodDelete, srv.URL+fmt.Sprintf("/apps/house-info/__lightisle_kv/chunk_%d", i), nil)
		delReq.Header.Set("X-Test-User", "admin")
		delReq.Header.Set("X-LightIsle-Request", "1")
		dr, _ := http.DefaultClient.Do(delReq)
		dr.Body.Close()
	}
	for i := 0; i < maxKVKeysPerApp; i++ {
		r := put(fmt.Sprintf("k_%02d", i), `{"i":1}`)
		r.Body.Close()
		if r.StatusCode != http.StatusOK {
			t.Fatalf("expected key %d to succeed, got %d", i, r.StatusCode)
		}
	}
	rKeyLimit := put("k_overflow", `{"i":1}`)
	rKeyLimit.Body.Close()
	if rKeyLimit.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413 on 65th key, got %d", rKeyLimit.StatusCode)
	}

	// Concurrent updates to existing key remain race-free
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			r := put("k_00", fmt.Sprintf(`{"n":%d}`, n))
			r.Body.Close()
		}(i)
	}
	wg.Wait()
}
