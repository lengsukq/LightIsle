package auth

import (
	"errors"
	"path/filepath"
	"testing"
)

func TestAdminCreateDisable(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Setup("primary", "strong-initial-password"); err != nil {
		t.Fatal(err)
	}
	owner, err := s.Login("primary", "strong-initial-password")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateUser("fake", "guest", "password-for-guest", RoleMember); !errors.Is(err, ErrForbidden) {
		t.Fatalf("anonymous create: %v", err)
	}
	member, err := s.CreateUser(owner, "guest", "password-for-guest", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	guestToken, err := s.Login("guest", "password-for-guest")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateUser(guestToken, "third", "password-for-third", RoleMember); !errors.Is(err, ErrForbidden) {
		t.Fatalf("non-admin created account: %v", err)
	}
	if err := s.SetEnabled(owner, 1, false); !errors.Is(err, ErrForbidden) {
		t.Fatalf("founder disabled: %v", err)
	}
	ownerUser, ok := s.Identity(owner)
	if !ok {
		t.Fatal("owner session is invalid")
	}
	if err := s.SetEnabled(owner, ownerUser.ID, false); !errors.Is(err, ErrForbidden) {
		t.Fatalf("acting administrator disabled: %v", err)
	}
	if err := s.SetEnabled(owner, ownerUser.ID, true); err != nil {
		t.Fatalf("acting administrator could not restore own enabled state: %v", err)
	}
	if err := s.SetEnabled(owner, 1, true); err != nil {
		t.Fatalf("founder could not be re-enabled: %v", err)
	}
	if err := s.SetEnabled(owner, member.ID, false); err != nil {
		t.Fatal(err)
	}
	if s.Session(guestToken) {
		t.Fatal("disabled session still valid")
	}
	if _, err := s.Login("guest", "password-for-guest"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("disabled login: %v", err)
	}
	if err := s.SetEnabled(owner, member.ID, true); err != nil {
		t.Fatal(err)
	}
	users, err := s.ListUsers(owner)
	if err != nil || len(users) != 2 {
		t.Fatalf("list: %#v %v", users, err)
	}
	if _, err := s.ListUsers(guestToken); !errors.Is(err, ErrForbidden) {
		t.Fatalf("guest list: %v", err)
	}
}
