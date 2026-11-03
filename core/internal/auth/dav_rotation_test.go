package auth

import (
	"errors"
	"path/filepath"
	"testing"
)

func TestDAVCredentialRotationRevokesOldPasswordAndPreservesOwner(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	owner, err := store.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateUser(owner, "member", "member-password-12345", RoleMember); err != nil {
		t.Fatal(err)
	}
	member, err := store.Login("member", "member-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	credential, oldPassword, err := store.CreateDAVCredential(owner, "Finder")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.VerifyDAVCredential("owner", oldPassword); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RotateDAVCredential(member, credential.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("another account must not rotate this credential: %v", err)
	}
	if _, err := store.VerifyDAVCredential("owner", oldPassword); err != nil {
		t.Fatalf("unauthorized rotation must leave original password valid: %v", err)
	}
	newPassword, err := store.RotateDAVCredential(owner, credential.ID)
	if err != nil {
		t.Fatal(err)
	}
	if newPassword == oldPassword {
		t.Fatal("password did not rotate")
	}
	if _, err := store.VerifyDAVCredential("owner", oldPassword); !errors.Is(err, ErrForbidden) {
		t.Fatalf("old password still accepted: %v", err)
	}
	if _, err := store.VerifyDAVCredential("owner", newPassword); err != nil {
		t.Fatalf("replacement credential rejected: %v", err)
	}
	credentials, err := store.ListDAVCredentials(owner)
	if err != nil || len(credentials) != 1 || credentials[0].ID != credential.ID || credentials[0].Label != "Finder" {
		t.Fatalf("rotation must preserve credential metadata: %+v, %v", credentials, err)
	}
	if credential.Revision == "" || credentials[0].Revision == "" ||
		credentials[0].Revision == credential.Revision {
		t.Fatalf("password rotation must change the non-secret credential revision: old=%q new=%q", credential.Revision, credentials[0].Revision)
	}
	if _, err := store.RotateDAVCredential(owner, credential.ID+999); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown credential must be rejected: %v", err)
	}
}
