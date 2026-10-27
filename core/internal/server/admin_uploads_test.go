package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestAdminUploadListAndCancelAfterWriteGrantRevocation(t *testing.T) {
	dir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "admin-password-12345"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "admin-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(admin, "member", "member-password-12345", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberSession, err := accounts.Login("member", "member-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	storage, err := files.NewManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	if err := storage.Mkdir("family"); err != nil {
		t.Fatal(err)
	}
	if err := accounts.SetFileGrant(admin, member.ID, "family", true); err != nil {
		t.Fatal(err)
	}
	handler := New("", accounts, storage)
	call := func(method, route, body, session string, headers map[string]string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, route, bytes.NewBufferString(body))
		req.Header.Set("X-LightIsle-Request", "1")
		for name, value := range headers {
			req.Header.Set(name, value)
		}
		if session != "" {
			req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, req)
		return response
	}
	begin := func(name string) string {
		t.Helper()
		response := call(http.MethodPost, "/api/v2/uploads", `{"path":"family/`+name+`","size":8}`, memberSession, nil)
		if response.Code != http.StatusCreated {
			t.Fatalf("begin upload %s: %d %s", name, response.Code, response.Body.String())
		}
		var state files.UploadState
		if err := json.Unmarshal(response.Body.Bytes(), &state); err != nil || state.ID == "" {
			t.Fatalf("begin response %s: %+v err=%v", response.Body.String(), state, err)
		}
		return state.ID
	}
	ownerCancelID := begin("owner-cancel.bin")
	adminCancelID := begin("admin-cancel.bin")

	for _, identity := range []struct {
		session string
		status  int
	}{{"", http.StatusUnauthorized}, {memberSession, http.StatusForbidden}} {
		response := call(http.MethodGet, "/api/v2/admin/uploads", "", identity.session, nil)
		if response.Code != identity.status {
			t.Fatalf("admin list permission: got %d want %d: %s", response.Code, identity.status, response.Body.String())
		}
	}
	listed := call(http.MethodGet, "/api/v2/admin/uploads?limit=1", "", admin, nil)
	if listed.Code != http.StatusOK {
		t.Fatalf("admin list: %d %s", listed.Code, listed.Body.String())
	}
	var first struct {
		Uploads    []map[string]any `json:"uploads"`
		NextCursor string           `json:"nextCursor"`
	}
	if err := json.Unmarshal(listed.Body.Bytes(), &first); err != nil || len(first.Uploads) != 1 || first.NextCursor == "" {
		t.Fatalf("admin upload page: %+v err=%v", first, err)
	}
	second := call(http.MethodGet, "/api/v2/admin/uploads?limit=1&after="+first.NextCursor, "", admin, nil)
	if second.Code != http.StatusOK {
		t.Fatalf("second upload page: %d %s", second.Code, second.Body.String())
	}
	var secondPage struct {
		Uploads []struct {
			ID            string `json:"id"`
			OwnerID       int64  `json:"ownerID"`
			OwnerName     string `json:"ownerName"`
			OwnerEnabled  bool   `json:"ownerEnabled"`
			OwnerMissing  bool   `json:"ownerMissing"`
			OwnerCanWrite bool   `json:"ownerCanWrite"`
			Path          string `json:"path"`
			Size          int64  `json:"size"`
			Offset        int64  `json:"offset"`
			Created       int64  `json:"created"`
			Activity      int64  `json:"activity"`
			Published     bool   `json:"published"`
			Orphan        bool   `json:"orphan"`
		} `json:"uploads"`
		NextCursor string `json:"nextCursor"`
	}
	if err := json.Unmarshal(second.Body.Bytes(), &secondPage); err != nil || len(secondPage.Uploads) != 1 || secondPage.NextCursor != "" {
		t.Fatalf("second upload page: %+v err=%v", secondPage, err)
	}
	item := secondPage.Uploads[0]
	if item.OwnerID != member.ID || item.OwnerName != "member" || !item.OwnerEnabled || item.OwnerMissing || !item.OwnerCanWrite ||
		item.Path != "family/owner-cancel.bin" && item.Path != "family/admin-cancel.bin" || item.Size != 8 || item.Offset != 0 ||
		item.Created <= 0 || item.Activity <= 0 || item.Published || item.Orphan {
		t.Fatalf("unexpected admin upload fields: %+v", item)
	}

	if err := accounts.RemoveFileGrant(admin, member.ID, "family"); err != nil {
		t.Fatal(err)
	}
	listed = call(http.MethodGet, "/api/v2/admin/uploads?limit=100", "", admin, nil)
	if listed.Code != http.StatusOK {
		t.Fatalf("admin list after grant revocation: %d %s", listed.Code, listed.Body.String())
	}
	var revoked struct {
		Uploads []struct {
			ID            string `json:"id"`
			OwnerEnabled  bool   `json:"ownerEnabled"`
			OwnerMissing  bool   `json:"ownerMissing"`
			OwnerCanWrite bool   `json:"ownerCanWrite"`
			Orphan        bool   `json:"orphan"`
		} `json:"uploads"`
	}
	if err := json.Unmarshal(listed.Body.Bytes(), &revoked); err != nil || len(revoked.Uploads) != 2 {
		t.Fatalf("uploads after grant revocation: %+v err=%v", revoked, err)
	}
	for _, upload := range revoked.Uploads {
		if !upload.OwnerEnabled || upload.OwnerMissing || upload.OwnerCanWrite || upload.Orphan {
			t.Fatalf("revoked owner was misclassified as an orphan: %+v", upload)
		}
	}
	denied := call(http.MethodPatch, "/api/v2/uploads/"+ownerCancelID, "bytes", memberSession, map[string]string{"X-Upload-Offset": "0"})
	if denied.Code != http.StatusForbidden {
		t.Fatalf("revoked member upload write status=%d body=%s", denied.Code, denied.Body.String())
	}
	ownerCancelled := call(http.MethodDelete, "/api/v2/uploads/"+ownerCancelID, "", memberSession, nil)
	if ownerCancelled.Code != http.StatusOK {
		t.Fatalf("owner could not discard upload after grant revocation: %d %s", ownerCancelled.Code, ownerCancelled.Body.String())
	}
	adminCancelled := call(http.MethodDelete, "/api/v2/admin/uploads/"+adminCancelID, "", admin, nil)
	if adminCancelled.Code != http.StatusOK {
		t.Fatalf("admin could not cancel upload: %d %s", adminCancelled.Code, adminCancelled.Body.String())
	}
	missing := call(http.MethodDelete, "/api/v2/uploads/"+adminCancelID, "", memberSession, nil)
	if missing.Code != http.StatusNotFound {
		t.Fatalf("owner DELETE after admin cancellation status=%d body=%s", missing.Code, missing.Body.String())
	}
}

func TestAdminExpiredUploadCleanupRequiresExplicitSupportedPeriod(t *testing.T) {
	dir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "admin-password-12345"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "admin-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	storage, err := files.NewManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	state, err := storage.BeginUpload("old.bin", 8, 1)
	if err != nil {
		t.Fatal(err)
	}
	// Move only the journal's activity timestamp back to exercise the explicit
	// age threshold without waiting or changing the staged bytes.
	journalPath := filepath.Join(dir, "SharedFiles", ".lightisle-parts", state.ID+".json")
	var journal files.UploadState
	data, err := os.ReadFile(journalPath)
	if err != nil || json.Unmarshal(data, &journal) != nil {
		t.Fatalf("read upload journal: %v", err)
	}
	journal.Activity = time.Now().Add(-8 * 24 * time.Hour).Unix()
	data, err = json.Marshal(journal)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(journalPath, data, 0600); err != nil {
		t.Fatal(err)
	}
	handler := New("", accounts, storage)
	call := func(body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/api/v2/admin/uploads/cleanup-expired", bytes.NewBufferString(body))
		req.Header.Set("X-LightIsle-Request", "1")
		req.AddCookie(&http.Cookie{Name: sessionCookie, Value: admin})
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, req)
		return response
	}
	for _, body := range []string{"", `{}`, `{"inactiveForSeconds":1}`, `{"inactiveForSeconds":604800,"extra":true}`} {
		if response := call(body); response.Code != http.StatusBadRequest {
			t.Errorf("invalid expiry request %q: %d %s", body, response.Code, response.Body.String())
		}
	}
	response := call(`{"inactiveForSeconds":604800}`)
	if response.Code != http.StatusOK {
		t.Fatalf("explicit expiry cleanup: %d %s", response.Code, response.Body.String())
	}
	var result struct {
		Removed           int      `json:"removed"`
		RemovedIDs        []string `json:"removedIDs"`
		Skipped           int      `json:"skipped"`
		HasMore           bool     `json:"hasMore"`
		InactiveForSecond int64    `json:"inactiveForSeconds"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil || result.Removed != 1 || len(result.RemovedIDs) != 1 ||
		result.RemovedIDs[0] != state.ID || result.Skipped != 0 || result.HasMore || result.InactiveForSecond != 604800 {
		t.Fatalf("cleanup response: %+v err=%v", result, err)
	}
}
