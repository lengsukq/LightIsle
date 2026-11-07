package auth

import (
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
)

func TestUploadCleanupRulesPersistAndRequireAdmin(t *testing.T) {
	file := filepath.Join(t.TempDir(), "accounts.sqlite")
	s, err := Open(file)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Setup("owner", "upload-cleanup-owner-password"); err != nil {
		t.Fatal(err)
	}
	admin, err := s.Login("owner", "upload-cleanup-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateUser(admin, "member", "upload-cleanup-member-password", RoleMember); err != nil {
		t.Fatal(err)
	}
	member, err := s.Login("member", "upload-cleanup-member-password")
	if err != nil {
		t.Fatal(err)
	}
	if days, err := s.UploadRetentionDays(); err != nil || days != 30 {
		t.Fatalf("default=%d err=%v", days, err)
	}
	if err := s.SetUploadRetentionDays(member, 7); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member changed rules: %v", err)
	}
	for _, invalid := range []int{-1, 3651} {
		if err := s.SetUploadRetentionDays(admin, invalid); !errors.Is(err, ErrInput) {
			t.Fatalf("invalid days %d accepted: %v", invalid, err)
		}
	}
	if err := s.SetUploadRetentionDays(admin, 0); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(file)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.Close() }()
	if days, err := s.UploadRetentionDays(); err != nil || days != 0 {
		t.Fatalf("disabled setting not persisted: %d %v", days, err)
	}
	if _, err := s.db.Exec(`DELETE FROM upload_cleanup_settings WHERE id=1`); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(file)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.UploadRetentionDays(); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("lost policy was silently re-enabled after restart: %v", err)
	}
	if err := s.SetUploadRetentionDays(admin, 0); err != nil {
		t.Fatal(err)
	}
	if days, err := s.UploadRetentionDays(); err != nil || days != 0 {
		t.Fatalf("explicit safe repair failed: %d %v", days, err)
	}
}

func TestUploadCleanupReleasesOnlyExactRootAndReservation(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Setup("owner", "upload-cleanup-owner-password"); err != nil {
		t.Fatal(err)
	}
	admin, err := s.Login("owner", "upload-cleanup-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	user, err := s.CreateUser(admin, "member", "upload-cleanup-member-password", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	member, err := s.Login("member", "upload-cleanup-member-password")
	if err != nil {
		t.Fatal(err)
	}
	const root = "11111111111111111111111111111111"
	const upload = "22222222222222222222222222222222"
	location, err := s.AssignUserStorage(admin, user.ID, StoragePhotos, root, 3)
	if err != nil {
		t.Fatal(err)
	}
	path := fmt.Sprintf("%s/test.jpg", location.RelativePath)
	id, tracked, err := s.ReserveStorageUpload(member, root, 3, path, 5)
	if err != nil || !tracked {
		t.Fatalf("reservation: %v %v", tracked, err)
	}
	for _, attempt := range []struct {
		generation uint64
		path       string
		size       int64
	}{
		{4, path, 5}, {3, path + "-changed", 5}, {3, path, 6},
	} {
		if err := s.ReleaseUnlinkedStorageReservation(id, root, attempt.generation, attempt.path, attempt.size); !errors.Is(err, ErrStorageReservationMissing) {
			t.Fatalf("wrong unlinked reservation accepted: %+v %v", attempt, err)
		}
	}
	if err := s.LinkStorageUpload(id, upload); err != nil {
		t.Fatal(err)
	}
	if err := s.ReleaseUnlinkedStorageReservation(id, root, 3, path, 5); !errors.Is(err, ErrStorageReservationMissing) {
		t.Fatalf("linked upload reservation released: %v", err)
	}
	if _, _, _, _, err := s.UploadReservationForCleanup(root, 4, upload); !errors.Is(err, ErrStorageLedgerConflict) {
		t.Fatalf("wrong generation accepted: %v", err)
	}
	gotID, gotPath, owner, found, err := s.UploadReservationForCleanup(root, 3, upload)
	if err != nil || !found || gotID != id || gotPath != path || owner != user.ID {
		t.Fatalf("lookup: %q %q %v %v", gotID, gotPath, found, err)
	}
	if err := s.ReleaseCleanedUploadReservation(id, root, 3, upload, path+"-changed", owner); !errors.Is(err, ErrStorageReservationMissing) {
		t.Fatalf("changed reservation released: %v", err)
	}
	if err := s.ReleaseCleanedUploadReservation(id, root, 3, upload, path, owner); err != nil {
		t.Fatal(err)
	}
	if _, _, _, found, err := s.UploadReservationForCleanup(root, 3, upload); err != nil || found {
		t.Fatalf("released reservation remains: %v %v", found, err)
	}
}
