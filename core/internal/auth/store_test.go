package auth

import (
	"errors"
	"path/filepath"
	"testing"
)

func TestSetupLoginPersistSessionAndLogout(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lightisle.sqlite")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if ok, _ := s.Configured(); ok {
		t.Fatal("already initialized")
	}
	if err := s.Setup("leo", "short"); !errors.Is(err, ErrInput) {
		t.Fatalf("weak password accepted: %v", err)
	}
	if err := s.Setup("leo", "long-password-good-2026"); err != nil {
		t.Fatal(err)
	}
	if ok, _ := s.Configured(); !ok {
		t.Fatal("not initialized")
	}
	if err := s.Setup("other", "long-password-good-2026"); !errors.Is(err, ErrExists) {
		t.Fatalf("allowed second admin: %v", err)
	}
	if _, err := s.Login("leo", "wrong-password"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("bad login: %v", err)
	}
	token, err := s.Login("leo", "long-password-good-2026")
	if err != nil {
		t.Fatal(err)
	}
	if !s.Session(token) || s.Username(token) != "leo" {
		t.Fatal("session invalid")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if !s.Session(token) {
		t.Fatal("session not persisted")
	}
	s.Logout(token)
	if s.Session(token) {
		t.Fatal("logout did not invalidate")
	}
}

func TestFirstAdminResetRevokesSessionsAndPreservesOtherUsers(t *testing.T) {
    store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
    if err != nil { t.Fatal(err) }
    defer store.Close()
    if err := store.ResetFirstAdminPassword("new-admin-password-2026"); !errors.Is(err, ErrNotFound) {
        t.Fatalf("unconfigured reset not rejected: %v", err)
    }
    if err := store.Setup("test_owner", "original-admin-password-2026"); err != nil { t.Fatal(err) }
    token, err := store.Login("test_owner", "original-admin-password-2026")
    if err != nil { t.Fatal(err) }
    _, err = store.CreateUser(token, "member", "member-password-2026", RoleMember)
    if err != nil { t.Fatal(err) }
    memberToken, err := store.Login("member", "member-password-2026")
    if err != nil { t.Fatal(err) }
    if err := store.ResetFirstAdminPassword("weak"); !errors.Is(err, ErrInput) {
        t.Fatalf("weak reset accepted: %v", err)
    }
    if !store.Session(token) { t.Fatal("invalid reset revoked existing session") }
    if err := store.ResetFirstAdminPassword("replacement-password-2026"); err != nil { t.Fatal(err) }
    if store.Session(token) { t.Fatal("old administrator session still valid") }
    if !store.Session(memberToken) { t.Fatal("unrelated member session was revoked") }
    if _, err := store.Login("test_owner", "original-admin-password-2026"); !errors.Is(err, ErrInvalid) {
        t.Fatalf("old password still valid: %v", err)
    }
    newToken, err := store.Login("test_owner", "replacement-password-2026")
    if err != nil || !store.Session(newToken) { t.Fatalf("new password not accepted: %v", err) }
}
