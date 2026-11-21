package server

import (
	"net/http"
	"testing"
)

func TestGlobalAndRootWritesRecordSingleAuditEntry(t *testing.T) {
	f := newRootRoutingFixture(t)

	// 1. Global write endpoint: POST /api/v2/users
	createUser := f.call(f.admin, http.MethodPost, "/api/v2/users", `{"username":"member-audit","password":"member-password-12345"}`)
	if createUser.Code != http.StatusCreated {
		t.Fatalf("POST /api/v2/users = %d %s", createUser.Code, createUser.Body.String())
	}
	if got := createUser.Header().Get("X-Content-Type-Options"); got != "nosniff" {
		t.Fatalf("missing security header X-Content-Type-Options: %q", got)
	}
	if got := createUser.Header().Get("X-Frame-Options"); got != "DENY" {
		t.Fatalf("missing security header X-Frame-Options: %q", got)
	}
	events, _, err := f.accounts.ListAudit(f.admin, 0, 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 {
		t.Fatalf("expected exactly 1 audit entry for global POST /api/v2/users, got %d: %+v", len(events), events)
	}
	if events[0].Action != "user_or_grant_change" || events[0].Outcome != "success" {
		t.Fatalf("unexpected global audit event: %+v", events[0])
	}

	// 2. Second global write endpoint: PUT /api/v2/admin/cleanup-rules
	cleanup := f.call(f.admin, http.MethodPut, "/api/v2/admin/cleanup-rules", `{"uploadRetentionDays":14}`)
	if cleanup.Code != http.StatusOK {
		t.Fatalf("PUT /api/v2/admin/cleanup-rules = %d %s", cleanup.Code, cleanup.Body.String())
	}
	events, _, err = f.accounts.ListAudit(f.admin, 0, 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 {
		t.Fatalf("expected exactly 2 total audit entries after second global write, got %d: %+v", len(events), events)
	}
	if events[0].Action != "cleanup_rules_change" {
		t.Fatalf("unexpected cleanup audit event: %+v", events[0])
	}

	// 3. Root-scoped write endpoint: POST /api/v2/roots/{id}/files/folders
	mkdir := f.call(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/files/folders"), `{"path":"shared-folder"}`)
	if mkdir.Code != http.StatusCreated {
		t.Fatalf("POST root mkdir = %d %s", mkdir.Code, mkdir.Body.String())
	}
	events, _, err = f.accounts.ListAudit(f.admin, 0, 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 3 {
		t.Fatalf("expected exactly 3 total audit entries after root write, got %d: %+v", len(events), events)
	}
	if events[0].Action != "root_file_write" {
		t.Fatalf("unexpected root write audit event: %+v", events[0])
	}
}
