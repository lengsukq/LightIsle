package auth

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func TestTrashLedgerReleaseUsesExactIdentityAndRollsBackOnChange(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Setup("owner", "trash-owner-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := s.Login("owner", "trash-owner-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := s.CreateUser(admin, "member", "trash-member-password-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	session, err := s.Login("member", "trash-member-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateUser(admin, "outsider", "trash-outsider-password-2026", RoleMember); err != nil {
		t.Fatal(err)
	}
	outsiderSession, err := s.Login("outsider", "trash-outsider-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	const root = "11111111111111111111111111111111"
	const otherRoot = "22222222222222222222222222222222"
	location, err := s.AssignUserStorage(admin, member.ID, StorageFiles, root, 1)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.AssignUserStorage(admin, member.ID, StoragePhotos, otherRoot, 1); err != nil {
		t.Fatal(err)
	}
	base := location.RelativePath + "/folder"
	add := func(rootID, name, identity string, size int64) {
		t.Helper()
		id, tracked, err := s.ReserveStorageUpload(session, rootID, 1, name, size)
		if err != nil || !tracked {
			t.Fatalf("reserve %s: %v %v", name, tracked, err)
		}
		if err := s.CommitStorageReservationWithIdentity(id, identity); err != nil {
			t.Fatal(err)
		}
	}
	a, b := base+"/a", base+"/b"
	add(root, a, strings.Repeat("a", 64), 2)
	add(root, b, strings.Repeat("b", 64), 3)
	add(root, base+"-other", strings.Repeat("d", 64), 5)
	other := fmt.Sprintf("Users/u%d/photos/file", member.ID)
	add(otherRoot, other, strings.Repeat("e", 64), 7)
	snapshot, err := s.TrashLedgerSnapshot(session, root, 1, base)
	if err != nil || len(snapshot) != 2 || snapshot[0].Path != a || snapshot[1].Path != b {
		t.Fatalf("snapshot: %+v %v", snapshot, err)
	}
	if _, err := s.TrashLedgerSnapshot(outsiderSession, root, 1, base); !errors.Is(err, ErrForbidden) {
		t.Fatalf("outsider inspected accounting: %v", err)
	}
	if err := s.ReleaseTrashLedgerSnapshot(outsiderSession, root, 1, base, snapshot); !errors.Is(err, ErrForbidden) {
		t.Fatalf("outsider released accounting: %v", err)
	}
	// A later file under the same directory is not part of the captured item.
	add(root, base+"/new", strings.Repeat("c", 64), 11)
	// If one captured path has changed, deleting an earlier row must roll back.
	if _, err := s.db.Exec(`UPDATE user_storage_file_identities SET identity=? WHERE root_id=? AND root_generation=1 AND relative_path=?`, strings.Repeat("f", 64), root, b); err != nil {
		t.Fatal(err)
	}
	if err := s.ReleaseTrashLedgerSnapshot(admin, root, 1, base, snapshot); !errors.Is(err, ErrStorageLedgerConflict) {
		t.Fatalf("changed identity accepted: %v", err)
	}
	if got, err := s.StorageFileIdentity(root, 1, a); err != nil || got != snapshot[0].Identity {
		t.Fatalf("partial release: %q %v", got, err)
	}
	if _, err := s.db.Exec(`UPDATE user_storage_file_identities SET identity=? WHERE root_id=? AND root_generation=1 AND relative_path=?`, snapshot[1].Identity, root, b); err != nil {
		t.Fatal(err)
	}
	if err := s.ReleaseTrashLedgerSnapshot(admin, root, 1, base, append(snapshot, snapshot[0])); !errors.Is(err, ErrStorageLedgerConflict) {
		t.Fatalf("duplicate accepted: %v", err)
	}
	unknown := append([]TrashLedgerFile(nil), snapshot...)
	unknown[0].Identity = ""
	if err := s.ReleaseTrashLedgerSnapshot(admin, root, 1, base, unknown); !errors.Is(err, ErrStorageLedgerConflict) {
		t.Fatalf("unknown identity accepted: %v", err)
	}
	if err := s.ReleaseTrashLedgerSnapshot(admin, root, 2, base, snapshot); !errors.Is(err, ErrStorageLedgerConflict) {
		t.Fatalf("different generation accepted: %v", err)
	}
	if err := s.ReleaseTrashLedgerSnapshot(admin, root, 1, base, snapshot); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{base + "/new", base + "-other"} {
		if identity, err := s.StorageFileIdentity(root, 1, name); err != nil || identity == "" {
			t.Fatalf("new charge %s lost: %q %v", name, identity, err)
		}
	}
	if identity, err := s.StorageFileIdentity(otherRoot, 1, other); err != nil || identity == "" {
		t.Fatalf("other root lost: %q %v", identity, err)
	}
	if meter, err := s.StorageMeter(admin, member.ID); err != nil || meter.UsedBytes != 23 {
		t.Fatalf("incorrect remaining usage: %+v %v", meter, err)
	}
	if err := s.ReleaseTrashLedgerSnapshot(admin, root, 1, base, snapshot); !errors.Is(err, ErrStorageLedgerConflict) {
		t.Fatalf("repeated release accepted: %v", err)
	}
}

func TestDirectoryRenameUpdatesLedgerPathsAndPreservesIdentities(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Setup("owner", "trash-owner-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := s.Login("owner", "trash-owner-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := s.CreateUser(admin, "member", "trash-member-password-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	session, err := s.Login("member", "trash-member-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	const root = "11111111111111111111111111111111"
	location, err := s.AssignUserStorage(admin, member.ID, StorageFiles, root, 1)
	if err != nil {
		t.Fatal(err)
	}
	srcDir := location.RelativePath + "/project"
	dstDir := location.RelativePath + "/project-renamed"
	id1, tracked, err := s.ReserveStorageUpload(session, root, 1, srcDir+"/sub/doc.txt", 10)
	if err != nil || !tracked {
		t.Fatalf("reserve doc: %v %v", tracked, err)
	}
	ident1 := strings.Repeat("1", 64)
	if err := s.CommitStorageReservationWithIdentity(id1, ident1); err != nil {
		t.Fatal(err)
	}
	renameID, snapshot, err := s.ReserveStorageDirectoryRename(session, root, 1, srcDir, dstDir)
	if err != nil || len(snapshot) != 1 || snapshot[0].Path != srcDir+"/sub/doc.txt" {
		t.Fatalf("reserve dir rename: %s %+v %v", renameID, snapshot, err)
	}
	if err := s.CommitStorageDirectoryRename(renameID, root, 1, srcDir, dstDir, snapshot); err != nil {
		t.Fatal(err)
	}
	if got, err := s.StorageFileIdentity(root, 1, dstDir+"/sub/doc.txt"); err != nil || got != ident1 {
		t.Fatalf("renamed identity: %q %v", got, err)
	}
	if got, err := s.StorageFileIdentity(root, 1, srcDir+"/sub/doc.txt"); err != nil || got != "" {
		t.Fatalf("old path remained: %q %v", got, err)
	}
	if meter, err := s.StorageMeter(admin, member.ID); err != nil || meter.UsedBytes != 10 {
		t.Fatalf("meter after directory rename: %+v %v", meter, err)
	}
}

