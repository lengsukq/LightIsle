package auth

import (
	"errors"
	"fmt"
	"path/filepath"
	"testing"
)

func TestPerDiskMigrationPreservesOfflineReservationsAndNewDiskDefault(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "accounts.sqlite")
	s, err := Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Setup("owner", "owner-per-disk-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, _ := s.Login("owner", "owner-per-disk-password-2026")
	member, err := s.CreateUser(admin, "member", "member-per-disk-password-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	session, _ := s.Login("member", "member-per-disk-password-2026")
	const a = "11111111111111111111111111111111"
	const b = "22222222222222222222222222222222"
	const c = "33333333333333333333333333333333"
	for _, location := range []struct {
		category, root string
		gen            uint64
	}{
		{StorageFiles, a, 2}, {StorageVideos, b, 3},
	} {
		if _, err := s.AssignUserStorage(admin, member.ID, location.category, location.root, location.gen); err != nil {
			t.Fatal(err)
		}
	}
	oldPending, tracked, err := s.ReserveStorageUpload(session, a, 2, fmt.Sprintf("Users/u%d/files/unfinished", member.ID), 80)
	if err != nil || !tracked {
		t.Fatalf("seed pending reservation: %v", err)
	}
	if _, _, err := s.ReserveStorageUpload(session, b, 3, fmt.Sprintf("Users/u%d/videos/original", member.ID), 70); err != nil {
		t.Fatal(err)
	}
	// Simulate upgrading a database from the pre-per-disk release. The
	// legacy quota and pending disk data already exist before first migration.
	if _, err := s.db.Exec(`INSERT INTO user_storage_quotas(user_id,quota_bytes,updated_at) VALUES(?,?,123)`, member.ID, 90); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`DELETE FROM storage_quota_migrations WHERE name='per_disk_v1'`); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.Close() }()
	policy, err := s.StoragePolicy(session, member.ID)
	if err != nil || policy.QuotaBytes != nil || len(policy.RootQuotas) != 2 {
		t.Fatalf("migration policy: %+v %v", policy, err)
	}
	for _, root := range policy.RootQuotas {
		if root.QuotaBytes == nil || *root.QuotaBytes != 90 {
			t.Fatalf("old configured per-user limit not migrated onto original root: %+v", root)
		}
	}
	before, err := s.StorageRootMeter(session, member.ID, a, 2)
	if err != nil || before.ReservedBytes != 80 || before.AvailableBytes == nil || *before.AvailableBytes != 10 {
		t.Fatalf("offline reservation lost or freed: %+v %v", before, err)
	}
	if _, tracked, err := s.ReserveStorageUpload(session, a, 2, fmt.Sprintf("Users/u%d/files/over", member.ID), 11); tracked || !errors.Is(err, ErrStorageQuotaExceeded) {
		t.Fatalf("migrated disk A limit bypassed: %v", err)
	}
	if err := s.CommitStorageReservation(oldPending); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AssignUserStorage(admin, member.ID, StoragePhotos, c, 1); err != nil {
		t.Fatal(err)
	}
	newRoot, err := s.StorageRootMeter(session, member.ID, c, 1)
	if err != nil || newRoot.AvailableBytes == nil || *newRoot.AvailableBytes != DefaultMemberQuotaBytes {
		t.Fatalf("new disk incorrectly inherited old global setting: %+v %v", newRoot, err)
	}
	if err := s.SetUserStorageRootQuota(admin, member.ID, b, 3, 77); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	bRoot, err := s.StorageRootMeter(session, member.ID, b, 3)
	if err != nil || bRoot.AvailableBytes == nil || *bRoot.AvailableBytes != 7 {
		t.Fatalf("per-disk customization overwritten by repeated migration: %+v %v", bRoot, err)
	}
	newRoot, err = s.StorageRootMeter(session, member.ID, c, 1)
	if err != nil || newRoot.AvailableBytes == nil || *newRoot.AvailableBytes != DefaultMemberQuotaBytes {
		t.Fatalf("newly added disk inherited legacy quota at next open: %+v %v", newRoot, err)
	}
}

func TestPerDiskQuotaIsSharedByCategoriesOnlyOnThatDisk(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Setup("owner", "owner-separate-disks-2026"); err != nil {
		t.Fatal(err)
	}
	admin, _ := s.Login("owner", "owner-separate-disks-2026")
	member, err := s.CreateUser(admin, "member", "member-separate-disks-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	session, _ := s.Login("member", "member-separate-disks-2026")
	const a = "11111111111111111111111111111111"
	const b = "22222222222222222222222222222222"
	for _, item := range []struct{ cat, root string }{{StorageFiles, a}, {StoragePhotos, a}, {StorageVideos, b}} {
		if _, err := s.AssignUserStorage(admin, member.ID, item.cat, item.root, 1); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.SetUserStorageRootQuota(admin, member.ID, a, 1, 100); err != nil {
		t.Fatal(err)
	}
	if err := s.SetUserStorageRootQuota(admin, member.ID, b, 1, 100); err != nil {
		t.Fatal(err)
	}
	for _, item := range []struct {
		root, category, name string
		size                 int64
	}{
		{a, StorageFiles, "a.bin", 60}, {a, StoragePhotos, "photo.jpg", 40}, {b, StorageVideos, "video.mp4", 100},
	} {
		file := fmt.Sprintf("Users/u%d/%s/%s", member.ID, item.category, item.name)
		_, tracked, err := s.ReserveStorageUpload(session, item.root, 1, file, item.size)
		if err != nil || !tracked {
			t.Fatalf("independent disk reservation %s: %v", file, err)
		}
	}
	for _, item := range []struct{ root, category string }{{a, StorageFiles}, {a, StoragePhotos}, {b, StorageVideos}} {
		file := fmt.Sprintf("Users/u%d/%s/excess", member.ID, item.category)
		if _, _, err := s.ReserveStorageUpload(session, item.root, 1, file, 1); !errors.Is(err, ErrStorageQuotaExceeded) {
			t.Fatalf("same disk categories exceeded shared limit: %s %v", file, err)
		}
	}
	for _, item := range []struct {
		root string
		want int64
	}{{a, 100}, {b, 100}} {
		meter, err := s.StorageRootMeter(session, member.ID, item.root, 1)
		if err != nil || meter.ReservedBytes != item.want || meter.AvailableBytes == nil || *meter.AvailableBytes != 0 {
			t.Fatalf("incorrect independent disk meter %s %+v %v", item.root, meter, err)
		}
	}
	if err := s.SetUserStorageRootQuota(admin, member.ID, b, 1, 0); err != nil {
		t.Fatal(err)
	}
	if _, tracked, err := s.ReserveStorageUpload(session, b, 1,
		fmt.Sprintf("Users/u%d/videos/empty", member.ID), 0); tracked || !errors.Is(err, ErrStorageQuotaExceeded) {
		t.Fatalf("zero quota must block even zero-byte new files: tracked=%v err=%v", tracked, err)
	}
	if meter, err := s.StorageRootMeter(session, member.ID, a, 1); err != nil ||
		meter.AvailableBytes == nil || *meter.AvailableBytes != 0 {
		t.Fatalf("changing B quota affected disk A: %+v %v", meter, err)
	}
}
