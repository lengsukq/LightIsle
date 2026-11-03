package auth

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"
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

func TestLoginBoundsSessionsAndNativeVerificationDoesNotIssueOne(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	const password = "owner-password-12345"
	if err := store.Setup("owner", password); err != nil {
		t.Fatal(err)
	}
	first, err := store.Login("owner", password)
	if err != nil {
		t.Fatal(err)
	}
	user, ok := store.Identity(first)
	if !ok {
		t.Fatal("first session missing")
	}
	now := time.Now().Unix()
	for i := 0; i < maxAccountSessions-1; i++ {
		digest := sha256.Sum256([]byte(fmt.Sprintf("seeded session %d", i)))
		if _, err := store.db.Exec("INSERT INTO sessions(id,user_id,expires_at,created_at) VALUES(?,?,?,?)",
			digest[:], user.ID, now+3600, now); err != nil {
			t.Fatal(err)
		}
	}
	if !store.VerifyAdministrator("owner", password) || !store.Session(first) {
		t.Fatal("native verification failed or displaced an existing session")
	}
	latest, err := store.Login("owner", password)
	if err != nil {
		t.Fatal(err)
	}
	items, truncated, err := store.ListSessions(latest)
	if err != nil || truncated || len(items) != maxAccountSessions || store.Session(first) {
		t.Fatalf("session cap not enforced: size=%d truncated=%v err=%v", len(items), truncated, err)
	}
}

func TestRevokedAdministratorCannotFinishCreatingAccount(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	const password = "owner-password-12345"
	if err := store.Setup("owner", password); err != nil {
		t.Fatal(err)
	}
	token, err := store.Login("owner", password)
	if err != nil {
		t.Fatal(err)
	}
	store.afterAccountAuthorization = func() {
		if err := store.Logout(token); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := store.CreateUser(token, "new-admin", "new-password-12345", RoleAdmin); !errors.Is(err, ErrForbidden) {
		t.Fatalf("revoked administrator created account: %v", err)
	}
	if store.VerifyAdministrator("new-admin", "new-password-12345") {
		t.Fatal("account was persisted")
	}
}
