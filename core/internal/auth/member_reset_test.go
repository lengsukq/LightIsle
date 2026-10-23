package auth

import (
	"errors"
	"path/filepath"
	"testing"
)

func TestAdministratorCanResetOnlyActiveMembers(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "admin-password-12345"); err != nil {
		t.Fatal(err)
	}
	admin, err := store.Login("owner", "admin-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	owner, ok := store.Identity(admin)
	if !ok {
		t.Fatal("admin session invalid")
	}
	member, err := store.CreateUser(admin, "family", "family-password-12345", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	member1, err := store.Login("family", "family-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	member2, err := store.Login("family", "family-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.ResetMemberPassword(member1, member.ID, "new-family-password-12345"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member reset = %v", err)
	}
	if err := store.ResetMemberPassword(admin, owner.ID, "new-admin-password-12345"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("administrator reset = %v", err)
	}
	if err := store.ResetMemberPassword(admin, member.ID, "short"); !errors.Is(err, ErrInput) {
		t.Fatalf("short password = %v", err)
	}
	if !store.Session(member1) || !store.Session(member2) {
		t.Fatal("failed reset invalidated existing sessions")
	}
	if err := store.ResetMemberPassword(admin, member.ID, "new-family-password-12345"); err != nil {
		t.Fatal(err)
	}
	if store.Session(member1) || store.Session(member2) {
		t.Fatal("member sessions not revoked")
	}
	if _, err := store.Login("family", "family-password-12345"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("old credentials still work: %v", err)
	}
	newToken, err := store.Login("family", "new-family-password-12345")
	if err != nil || !store.Session(newToken) {
		t.Fatalf("new credentials rejected: %v", err)
	}
	if !store.Session(admin) {
		t.Fatal("admin session unexpectedly revoked")
	}
	if err := store.SetEnabled(admin, member.ID, false); err != nil {
		t.Fatal(err)
	}
	if err := store.ResetMemberPassword(admin, member.ID, "another-password-12345"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("disabled member reset = %v", err)
	}
	if err := store.ResetMemberPassword(admin, 0, "another-password-12345"); !errors.Is(err, ErrInput) {
		t.Fatalf("invalid ID = %v", err)
	}
	if err := store.ResetMemberPassword(admin, 99999, "another-password-12345"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing member = %v", err)
	}
}
