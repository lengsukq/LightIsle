package auth

import (
	"errors"
	"path/filepath"
	"testing"
)

func TestChangePasswordRevokesEverySessionAndPreservesOldPasswordOnFailure(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "old-password-123456"); err != nil {
		t.Fatal(err)
	}
	admin, err := store.Login("owner", "old-password-123456")
	if err != nil {
		t.Fatal(err)
	}
	member, err := store.CreateUser(admin, "someone", "old-member-password", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	first, err := store.Login(member.Username, "old-member-password")
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.Login(member.Username, "old-member-password")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.ChangePassword(first, "incorrect-old-password", "new-member-password"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("wrong old password returned %v", err)
	}
	if !store.Session(first) || !store.Session(second) {
		t.Fatal("failed change invalidated sessions")
	}
	if err := store.ChangePassword(first, "old-member-password", "old-member-password"); !errors.Is(err, ErrInput) {
		t.Fatalf("repeated password returned %v", err)
	}
	if err := store.ChangePassword(first, "old-member-password", "new-member-password"); err != nil {
		t.Fatal(err)
	}
	if store.Session(first) || store.Session(second) {
		t.Fatal("password change did not revoke both sessions")
	}
	if _, err := store.Login(member.Username, "old-member-password"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("old password still accepted: %v", err)
	}
	newSession, err := store.Login(member.Username, "new-member-password")
	if err != nil || !store.Session(newSession) {
		t.Fatalf("new password rejected: %v", err)
	}
	if !store.Session(admin) {
		t.Fatal("changing member password affected administrator")
	}
	if err := store.ChangePassword(first, "new-member-password", "another-password-12345"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("revoked session can change again: %v", err)
	}
}
