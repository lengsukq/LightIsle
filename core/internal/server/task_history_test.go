package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

func TestTaskHistoryIsAdminOnlyAndPaged(t *testing.T) {
	dir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "long-initial-password"); err != nil {
		t.Fatal(err)
	}
	adminSession, err := accounts.Login("owner", "long-initial-password")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := accounts.CreateUser(adminSession, "member", "member-password-12345", auth.RoleMember); err != nil {
		t.Fatal(err)
	}
	memberSession, err := accounts.Login("member", "member-password-12345")
	if err != nil {
		t.Fatal(err)
	}

	journal, err := tasks.Open(filepath.Join(dir, "data"))
	if err != nil {
		t.Fatal(err)
	}
	defer journal.Close()
	for _, item := range []struct {
		kind, operation string
		progress, bytes int64
		runErr          error
	}{
		{"gallery", "scan", 5, 50, errTaskHistoryTest},
		{"gallery", "scan", 12, 120, nil},
		{"backup", "backup", 3, 300, nil},
	} {
		if err := journal.Start(item.kind, item.operation); err != nil {
			t.Fatal(err)
		}
		if err := journal.Progress(item.kind, item.progress, item.bytes); err != nil {
			t.Fatal(err)
		}
		if err := journal.Finish(item.kind, item.runErr); err != nil {
			t.Fatal(err)
		}
	}
	handler := NewWithJournal("", accounts, nil, nil, nil, journal)
	request := func(query, session string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/tasks/history"+query, nil)
		if session != "" {
			req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, req)
		return response
	}
	if response := request("", ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous history status=%d body=%s", response.Code, response.Body.String())
	}
	if response := request("", memberSession); response.Code != http.StatusForbidden {
		t.Fatalf("member history status=%d body=%s", response.Code, response.Body.String())
	}
	first := request("?limit=2", adminSession)
	if first.Code != http.StatusOK {
		t.Fatalf("admin history status=%d body=%s", first.Code, first.Body.String())
	}
	var page struct {
		Runs       []tasks.Run `json:"runs"`
		NextCursor string      `json:"nextCursor"`
	}
	if err := json.Unmarshal(first.Body.Bytes(), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Runs) != 2 || page.Runs[0].Kind != "backup" || page.Runs[0].Progress != 3 ||
		page.Runs[0].Attempts != 1 || page.NextCursor == "" {
		t.Fatalf("first response does not match contract: %+v", page)
	}
	second := request("?limit=2&before="+page.NextCursor, adminSession)
	if second.Code != http.StatusOK {
		t.Fatalf("second history status=%d body=%s", second.Code, second.Body.String())
	}
	page = struct {
		Runs       []tasks.Run `json:"runs"`
		NextCursor string      `json:"nextCursor"`
	}{}
	if err := json.Unmarshal(second.Body.Bytes(), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Runs) != 1 || page.Runs[0].Kind != "gallery" || page.Runs[0].LastError != errTaskHistoryTest.Error() || page.NextCursor != "" {
		t.Fatalf("second response does not match contract: %+v", page)
	}
	filtered := request("?kind=gallery&limit=10", adminSession)
	if filtered.Code != http.StatusOK {
		t.Fatalf("filtered history status=%d body=%s", filtered.Code, filtered.Body.String())
	}
	page = struct {
		Runs       []tasks.Run `json:"runs"`
		NextCursor string      `json:"nextCursor"`
	}{}
	if err := json.Unmarshal(filtered.Body.Bytes(), &page); err != nil || len(page.Runs) != 2 || page.NextCursor != "" {
		t.Fatalf("filtered response: %+v err=%v", page, err)
	}
	for _, query := range []string{"?limit=101", "?limit=0", "?before=0", "?before=abc", "?kind=unknown"} {
		if response := request(query, adminSession); response.Code != http.StatusBadRequest {
			t.Errorf("query %q status=%d body=%s", query, response.Code, response.Body.String())
		}
	}
}

var errTaskHistoryTest = testTaskError("scan_failed")

type testTaskError string

func (e testTaskError) Error() string { return string(e) }
