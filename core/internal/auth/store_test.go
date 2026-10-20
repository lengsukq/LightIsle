package auth

import (
	"crypto/sha256"
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

func TestRecoveryWhenFirstAdminHasMigratedID(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.Setup("primary_admin", "initial-primary-password-2026"); err != nil {
		t.Fatal(err)
	}
	// Simulate migrated/imported SQLite databases whose first admin is not id 1.
	if _, err := db.db.Exec("UPDATE users SET id=27 WHERE id=1"); err != nil {
		t.Fatal(err)
	}
	before, err := db.Login("primary_admin", "initial-primary-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	username, err := db.FirstAdminUsername()
	if err != nil || username != "primary_admin" {
		t.Fatalf("admin lookup: %q %v", username, err)
	}
	changed, err := db.ResetFirstAdminPassword("new-primary-password-2026")
	if err != nil || changed != username {
		t.Fatalf("reset: %q %v", changed, err)
	}
	if db.Session(before) {
		t.Fatal("previous session was not invalidated")
	}
	if _, err := db.Login(username, "initial-primary-password-2026"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("old password still works: %v", err)
	}
	if _, err := db.Login(username, "new-primary-password-2026"); err != nil {
		t.Fatalf("new password does not log in: %v", err)
	}
	otherAdminToken, err := db.Login(username, "new-primary-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	other, err := db.CreateUser(otherAdminToken, "second_admin", "second-admin-password-2026", RoleAdmin)
	if err != nil {
		t.Fatal(err)
	}
	secondaryAdminToken, err := db.Login("second_admin", "second-admin-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	if err := db.SetEnabled(secondaryAdminToken, 27, false); !errors.Is(err, ErrForbidden) {
		t.Fatalf("secondary admin disabled migrated primary: %v", err)
	}
	if err := db.SetEnabled(secondaryAdminToken, other.ID, false); !errors.Is(err, ErrForbidden) {
		t.Fatalf("secondary admin disabled itself: %v", err)
	}
	if err := db.SetEnabled(secondaryAdminToken, 27, true); err != nil {
		t.Fatalf("secondary admin could not restore migrated primary: %v", err)
	}
}

func TestLoginRejectsSessionFromStaleVerification(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("stale_admin", "original-admin-password-2026"); err != nil {
		t.Fatal(err)
	}
	store.afterVerify = func() {
		if _, err := store.ResetFirstAdminPassword("replacement-password-2026"); err != nil {
			t.Errorf("reset during login: %v", err)
		}
	}
	token, err := store.Login("stale_admin", "original-admin-password-2026")
	if token != "" || !errors.Is(err, ErrInvalid) {
		t.Fatalf("stale login returned %q, %v", token, err)
	}
	var sessions int
	if err := store.db.QueryRow("SELECT COUNT(*) FROM sessions").Scan(&sessions); err != nil {
		t.Fatal(err)
	}
	if sessions != 0 {
		t.Fatalf("stale login left %d session rows", sessions)
	}
	store.afterVerify = nil
	if _, err := store.Login("stale_admin", "replacement-password-2026"); err != nil {
		t.Fatalf("replacement password does not log in: %v", err)
	}
}

func TestSessionExpiresAfterConfiguredLifetime(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("expiry_admin", "long-expiry-password-2026"); err != nil {
		t.Fatal(err)
	}
	token, err := store.Login("expiry_admin", "long-expiry-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256([]byte(token))
	var expires, created int64
	if err := store.db.QueryRow("SELECT expires_at,created_at FROM sessions WHERE id=?", digest[:]).Scan(&expires, &created); err != nil {
		t.Fatal(err)
	}
	if delta := expires - created; delta != int64(SessionLifetime.Seconds()) {
		t.Fatalf("session lifetime = %d seconds, want %d", delta, int64(SessionLifetime.Seconds()))
	}
}

func TestFirstAdminResetRevokesSessionsAndPreservesOtherUsers(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, err := store.ResetFirstAdminPassword("new-admin-password-2026"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unconfigured reset not rejected: %v", err)
	}
	if err := store.Setup("test_owner", "original-admin-password-2026"); err != nil {
		t.Fatal(err)
	}
	token, err := store.Login("test_owner", "original-admin-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	_, err = store.CreateUser(token, "member", "member-password-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberToken, err := store.Login("member", "member-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ResetFirstAdminPassword("weak"); !errors.Is(err, ErrInput) {
		t.Fatalf("weak reset accepted: %v", err)
	}
	if !store.Session(token) {
		t.Fatal("invalid reset revoked existing session")
	}
	if user, err := store.ResetFirstAdminPassword("replacement-password-2026"); err != nil || user != "test_owner" {
		t.Fatalf("wrong recovery account %q %v", user, err)
	}
	if store.Session(token) {
		t.Fatal("old administrator session still valid")
	}
	if !store.Session(memberToken) {
		t.Fatal("unrelated member session was revoked")
	}
	if _, err := store.Login("test_owner", "original-admin-password-2026"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("old password still valid: %v", err)
	}
	newToken, err := store.Login("test_owner", "replacement-password-2026")
	if err != nil || !store.Session(newToken) {
		t.Fatalf("new password not accepted: %v", err)
	}
}
