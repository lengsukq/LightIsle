package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/automation"
	"github.com/lengsukq/lightisle/core/internal/notify"
)

func TestAutomationEndpointsAdminOnlyAndPreserveAgentEmailTemplate(t *testing.T) {
	dataDir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err = accounts.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = accounts.CreateUser(admin, "family", "family-password-12345", auth.RoleMember); err != nil {
		t.Fatal(err)
	}
	member, err := accounts.Login("family", "family-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	folder := filepath.Join(dataDir, "automation", "scripts", "daily-report")
	if err = os.MkdirAll(folder, 0700); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(folder, "run.sh"), []byte("#!/bin/sh\necho ready\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(folder, "email.html"), []byte("<p>{{run.state}}</p>"), 0600); err != nil {
		t.Fatal(err)
	}
	document := `{"schemaVersion":1,"id":"daily-report","name":"日报","enabled":false,"entry":"run.sh","schedule":{"cron":"0 8 * * *","timezone":"Asia/Shanghai"},"notification":{"events":["failure"],"channels":["email"],"email":{"mode":"content","file":"email.html","subject":"报告"}}}`
	if err = os.WriteFile(filepath.Join(folder, "task.json"), []byte(document), 0600); err != nil {
		t.Fatal(err)
	}
	automationManager, err := automation.New(dataDir, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer automationManager.Close()
	hub, err := notify.New(notify.Config{})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()
	handler := WithAutomation(New("", accounts, nil), accounts, automationManager, hub)
	call := func(method, path, session string, body []byte, header bool) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(method, path, bytes.NewReader(body))
		if session != "" {
			req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		if header {
			req.Header.Set("X-LightIsle-Request", "1")
		}
		out := httptest.NewRecorder()
		handler.ServeHTTP(out, req)
		return out
	}
	for _, path := range []string{"/api/v1/automation/tasks", "/api/v1/automation/channels", "/api/v1/automation/tasks/daily-report/runs"} {
		if got := call("GET", path, "", nil, false); got.Code != 401 {
			t.Fatalf("%s unauth=%d", path, got.Code)
		}
		if got := call("GET", path, member, nil, false); got.Code != 403 {
			t.Fatalf("%s member=%d", path, got.Code)
		}
		if got := call("GET", path, admin, nil, false); got.Code != 200 {
			t.Fatalf("%s admin=%d %s", path, got.Code, got.Body.String())
		}
	}
	endpoint := "/api/v1/automation/tasks/daily-report"
	update := []byte(`{"enabled":true,"schedule":{"cron":"30 8 * * *","timezone":"UTC"},"notification":{"events":["failure","timeout"],"channels":["email"]}}`)
	if got := call("PUT", endpoint, member, update, true); got.Code != 403 {
		t.Fatalf("member changed script: %d", got.Code)
	}
	if got := call("PUT", endpoint, admin, update, false); got.Code != 403 {
		t.Fatalf("no CSRF header accepted: %d", got.Code)
	}
	if got := call("PUT", endpoint, admin, update, true); got.Code != 200 {
		t.Fatalf("admin update failed: %d %s", got.Code, got.Body.String())
	}
	content, err := os.ReadFile(filepath.Join(folder, "task.json"))
	if err != nil {
		t.Fatal(err)
	}
	var persisted automation.Task
	if err = json.Unmarshal(content, &persisted); err != nil {
		t.Fatal(err)
	}
	if !persisted.Enabled || persisted.Schedule.Cron != "30 8 * * *" || persisted.Notification.Email == nil || persisted.Notification.Email.File != "email.html" {
		t.Fatalf("update changed agent-owned email config: %+v", persisted)
	}
	if got := call("DELETE", endpoint, admin, nil, true); got.Code != 200 {
		t.Fatalf("delete failed: %d %s", got.Code, got.Body.String())
	}
	if _, err = os.Stat(folder); !os.IsNotExist(err) {
		t.Fatalf("task directory still exists after delete: %v", err)
	}
}
