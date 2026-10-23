package auth

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAuditHistoryAdminOnlyCursorRetentionAndNoSecrets(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Setup("root", "strong-administrator-secret"); err != nil {
		t.Fatal(err)
	}
	admin, err := s.Login("root", "strong-administrator-secret")
	if err != nil {
		t.Fatal(err)
	}
	user, err := s.CreateUser(admin, "guest", "strong-guest-password", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	guest, err := s.Login("guest", "strong-guest-password")
	if err != nil {
		t.Fatal(err)
	}
	for _, action := range []string{"file_write", "gallery_write", "user_or_grant_change"} {
		if err := s.AppendAudit(user.ID, action, "POST /api/v1/test/{id}", "success"); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := s.ListAudit(guest, 0, 5); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member accessed audit history: %v", err)
	}
	if _, _, err := s.ListAudit(admin, 0, 101); !errors.Is(err, ErrInput) {
		t.Fatalf("unbounded page: %v", err)
	}
	page, next, err := s.ListAudit(admin, 0, 2)
	if err != nil || len(page) != 2 || next == 0 || page[0].Action != "user_or_grant_change" {
		t.Fatalf("first page: %+v cursor %d: %v", page, next, err)
	}
	older, cursor, err := s.ListAudit(admin, next, 2)
	if err != nil || len(older) != 1 || cursor != 0 || older[0].Action != "file_write" {
		t.Fatalf("older page dropped an event: %+v cursor %d: %v", older, cursor, err)
	}
	for _, target := range []string{"file?token=secret", "file\npassword=secret", "file&#secret"} {
		if err := s.AppendAudit(user.ID, "file_write", target, "success"); !errors.Is(err, ErrInput) {
			t.Fatalf("unescaped metadata accepted: %q %v", target, err)
		}
	}
	if _, err := s.db.Exec("UPDATE audit_events SET created_at=? WHERE action='file_write'", time.Now().Add(-100*24*time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}
	if err := s.AppendAudit(user.ID, "file_write", "POST /api/v1/files", "denied"); err != nil {
		t.Fatal(err)
	}
	all, _, err := s.ListAudit(admin, 0, 20)
	if err != nil || len(all) != 3 {
		t.Fatalf("old log was not pruned: %+v %v", all, err)
	}
	for _, row := range all {
		if strings.Contains(row.Target, "secret") || row.ActorID != user.ID {
			t.Fatalf("unsafe audit row: %+v", row)
		}
	}
}
