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
