package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

func TestSystemDiagnosticsAndMetricsHistoryAreAdminOnly(t *testing.T) {
	dir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(admin, "family", "family-password-12345", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	_ = member
	guest, err := accounts.Login("family", "family-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	journal, err := tasks.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer journal.Close()
	if err := journal.RecordMetric(tasks.MetricSample{Timestamp: time.Now().Unix(), MemoryPercent: 27, DiskPercent: 42}); err != nil {
		t.Fatal(err)
	}
	handler := NewWithJournal("", accounts, nil, nil, nil, journal)
	call := func(path, session string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, path, nil)
		if session != "" {
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		out := httptest.NewRecorder()
		handler.ServeHTTP(out, r)
		return out
	}
	for _, path := range []string{"/api/v1/system/history", "/api/v1/system/diagnostics"} {
		if r := call(path, ""); r.Code != http.StatusUnauthorized {
			t.Fatalf("%s unauth=%d", path, r.Code)
		}
		if r := call(path, guest); r.Code != http.StatusForbidden {
			t.Fatalf("%s member=%d", path, r.Code)
		}
		if r := call(path, admin); r.Code != http.StatusOK {
			t.Fatalf("%s admin=%d %s", path, r.Code, r.Body.String())
		}
	}
	if r := call("/api/v1/system/history?limit=9000", admin); r.Code != http.StatusBadRequest {
		t.Fatalf("limit unbounded=%d", r.Code)
	}
	if r := call("/api/v1/system/diagnostics?target=192.168.1.1", admin); r.Code != http.StatusBadRequest {
		t.Fatalf("unexpected arbitrary target %d", r.Code)
	}
	r := call("/api/v1/system/history", admin)
	var page struct {
		Samples []tasks.MetricSample `json:"samples"`
	}
	if err := json.Unmarshal(r.Body.Bytes(), &page); err != nil || len(page.Samples) != 1 {
		t.Fatalf("history=%s: %v", r.Body.String(), err)
	}
}
