package auth

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func TestStorageIdentityCommittedAtomicallyAndSurvivesRestart(t *testing.T) {
	db := filepath.Join(t.TempDir(), "accounts.sqlite")
	s, err := Open(db)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Setup("owner", "storage-owner-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := s.Login("owner", "storage-owner-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := s.CreateUser(admin, "member", "storage-member-password-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	session, err := s.Login("member", "storage-member-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	const root = "11111111111111111111111111111111"
	if _, err := s.AssignUserStorage(admin, member.ID, StorageFiles, root, 1); err != nil {
		t.Fatal(err)
	}
	name := fmt.Sprintf("Users/u%d/files/a.txt", member.ID)
	id, tracked, err := s.ReserveStorageUpload(session, root, 1, name, 3)
	if err != nil || !tracked {
		t.Fatalf("reserve: %v %v", tracked, err)
	}
	if err := s.CommitStorageReservationWithIdentity(id, "not-a-verified-identity"); !errors.Is(err, ErrInput) {
		t.Fatalf("invalid identity accepted: %v", err)
	}
	if meter, err := s.StorageMeter(admin, member.ID); err != nil || meter.UsedBytes != 0 || meter.ReservedBytes != 3 {
		t.Fatalf("invalid identity changed reservation: %+v %v", meter, err)
	}
	want := strings.Repeat("a", 64)
	if err := s.CommitStorageReservationWithIdentity(id, want); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(db)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if identity, err := s.StorageFileIdentity(root, 1, name); err != nil || identity != want {
		t.Fatalf("identity lost after restart: %q %v", identity, err)
	}
	destination := fmt.Sprintf("Users/u%d/files/renamed.txt", member.ID)
	rename, err := s.ReserveStorageRename(session, root, 1, name, destination)
	if err != nil {
		t.Fatal(err)
	}
	changed := strings.Repeat("b", 64)
	if _, err := s.db.Exec(`UPDATE user_storage_file_identities SET identity=? WHERE root_id=? AND root_generation=1 AND relative_path=?`, changed, root, name); err != nil {
		t.Fatal(err)
	}
	if err := s.CommitStorageRename(rename, root, 1, name, destination, 3, want); !errors.Is(err, ErrStorageLedgerConflict) {
		t.Fatalf("changed identity moved by stale operation: %v", err)
	}
	if identity, err := s.StorageFileIdentity(root, 1, name); err != nil || identity != changed {
		t.Fatalf("conflicting source identity modified: %q %v", identity, err)
	}
	if pending, _, err := s.StoragePendingReservations(admin, member.ID, "", 10); err != nil || len(pending) != 1 {
		t.Fatalf("conflicting rename reservation lost: %+v %v", pending, err)
	}
	if _, err := s.db.Exec(`UPDATE user_storage_file_identities SET identity=? WHERE root_id=? AND root_generation=1 AND relative_path=?`, want, root, name); err != nil {
		t.Fatal(err)
	}
	if err := s.CommitStorageRename(rename, root, 1, name, destination, 3, want); err != nil {
		t.Fatal(err)
	}
	if identity, err := s.StorageFileIdentity(root, 1, destination); err != nil || identity != want {
		t.Fatalf("verified identity did not follow rename: %q %v", identity, err)
	}
	if err := s.AbandonUserStorageLocation(admin, member.ID, StorageFiles, root, 1); err != nil {
		t.Fatal(err)
	}
	if identity, err := s.StorageFileIdentity(root, 1, name); err != nil || identity != "" {
		t.Fatalf("abandoned ledger left identity: %q %v", identity, err)
	}
	if identity, err := s.StorageFileIdentity(root, 1, destination); err != nil || identity != "" {
		t.Fatalf("abandoned renamed ledger left identity: %q %v", identity, err)
	}
}
