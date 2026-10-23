package auth

import (
	"errors"
	"path/filepath"
	"testing"
)

func TestSessionInventoryAndRevocationAreScopedToCurrentAccount(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	admin, err := store.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	member, err := store.CreateUser(admin, "member", "member-password-12345", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	first, err := store.Login(member.Username, "member-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.Login(member.Username, "member-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	list, truncated, err := store.ListSessions(first)
	if err != nil || truncated || len(list) != 2 {
		t.Fatalf("session list: %+v, %v, %v", list, truncated, err)
	}
	current := ""
	other := ""
	for _, session := range list {
		if session.CreatedAt <= 0 || session.ExpiresAt <= session.CreatedAt {
			t.Fatalf("invalid time: %+v", session)
		}
		if session.Current {
			current = session.ID
		} else {
			other = session.ID
		}
	}
	if current == "" || other == "" {
		t.Fatalf("current/other not identified: %+v", list)
	}
	if _, err := store.RevokeSession(first, "not-hex"); !errors.Is(err, ErrInput) {
		t.Fatalf("invalid ID: %v", err)
	}
	if _, err := store.RevokeSession(admin, other); err != nil {
		t.Fatal(err)
	}
	if !store.Session(second) {
		t.Fatal("admin session revoked someone else's token")
	}
	wasCurrent, err := store.RevokeSession(first, other)
	if err != nil || wasCurrent || store.Session(second) || !store.Session(first) {
		t.Fatalf("revoke other failed: %v / %t", err, wasCurrent)
	}
	third, err := store.Login(member.Username, "member-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	count, err := store.RevokeOtherSessions(first)
	if err != nil || count != 1 || !store.Session(first) || store.Session(third) || !store.Session(admin) {
		t.Fatalf("revoke others = %d %v", count, err)
	}
	wasCurrent, err = store.RevokeSession(first, current)
	if err != nil || !wasCurrent || store.Session(first) {
		t.Fatalf("revoke current: %v / %t", err, wasCurrent)
	}
	if _, _, err := store.ListSessions(first); !errors.Is(err, ErrForbidden) {
		t.Fatalf("revoked caller could list: %v", err)
	}
}
