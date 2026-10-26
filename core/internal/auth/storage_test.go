package auth

import (
	"errors"
	"fmt"
	"path/filepath"
	"testing"
)

func TestPersonalStorageQuotaDefaultsAdministrationAndPersistence(t *testing.T) {
	filename := filepath.Join(t.TempDir(), "accounts.sqlite")
	store, err := Open(filename)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Setup("owner", "owner-password-for-storage-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := store.Login("owner", "owner-password-for-storage-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := store.CreateUser(admin, "family", "family-password-for-storage-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberSession, err := store.Login("family", "family-password-for-storage-2026")
	if err != nil {
		t.Fatal(err)
	}

	ownerID := store.userIDForStorageTest(t, admin)
	ownerPolicy, err := store.StoragePolicy(admin, ownerID)
	if err != nil || ownerPolicy.QuotaBytes != nil {
		t.Fatalf("admin should have unlimited app quota: %+v %v", ownerPolicy, err)
	}
	defaultPolicy, err := store.StoragePolicy(memberSession, member.ID)
	if err != nil || defaultPolicy.QuotaBytes == nil || *defaultPolicy.QuotaBytes != DefaultMemberQuotaBytes ||
		defaultPolicy.Enforcement != "pending" {
		t.Fatalf("new member should show configured 100GiB but not assert enforcement: %+v %v", defaultPolicy, err)
	}
	if _, err := store.StoragePolicy(memberSession, ownerID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member can inspect another user's storage: %v", err)
	}
	if err := store.SetUserStorageQuota(memberSession, member.ID, 20<<30); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member changed its own quota: %v", err)
	}
	if err := store.SetUserStorageQuota(admin, ownerID, 5<<30); !errors.Is(err, ErrForbidden) {
		t.Fatalf("owner admin quota should not be configurable: %v", err)
	}
	if err := store.SetUserStorageQuota(admin, member.ID, MaxMemberQuotaBytes+1); !errors.Is(err, ErrInput) {
		t.Fatalf("accepted impossible quota: %v", err)
	}
	if err := store.SetUserStorageQuota(admin, member.ID, 20<<30); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = Open(filename)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy, err := store.StoragePolicy(memberSession, member.ID)
	if err != nil || policy.QuotaBytes == nil || *policy.QuotaBytes != 20<<30 {
		t.Fatalf("custom quota did not survive restart: %+v %v", policy, err)
	}
	if err := store.SetEnabled(admin, member.ID, false); err != nil {
		t.Fatal(err)
	}
	if err := store.SetUserStorageQuota(memberSession, member.ID, 25<<30); !errors.Is(err, ErrForbidden) {
		t.Fatalf("revoked user changed quota: %v", err)
	}
}

func TestPersonalHomePrivacyOverridesBroadRootGrant(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "owner-password-for-storage-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := store.Login("owner", "owner-password-for-storage-2026")
	if err != nil {
		t.Fatal(err)
	}
	first, err := store.CreateUser(admin, "member1", "member1-password-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.CreateUser(admin, "member2", "member2-password-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	const rootID = "0123456789abcdef0123456789abcdef"
	if err := store.SetRootGrant(admin, first.ID, rootID, ".", true); err != nil {
		t.Fatal(err)
	}
	firstSession, err := store.Login("member1", "member1-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	otherPath := fmt.Sprintf("Users/u%d/photos/family.jpg", second.ID)
	if store.CanAccessRoot(firstSession, rootID, otherPath, false, false) ||
		store.CanAccessRoot(firstSession, rootID, otherPath, true, false) ||
		store.CanSeeRoot(firstSession, rootID, otherPath) {
		t.Fatal("broad grant escaped assigned private home namespace")
	}
	if store.CanAccessRoot(firstSession, rootID, "Users", true, false) {
		t.Fatal("member with broad grant may not modify the parent of all private homes")
	}
	if _, err := store.AssignUserStorage(admin, first.ID, StoragePhotos, rootID, 1); err != nil {
		t.Fatal(err)
	}
	if _, err := store.AssignUserStorage(admin, second.ID, StoragePhotos, rootID, 1); err != nil {
		t.Fatal(err)
	}
	mediaScopes, err := store.SearchRootsRoot(firstSession, rootID, ".")
	if err != nil || len(mediaScopes) != 1 || mediaScopes[0] != fmt.Sprintf("Users/u%d/photos", first.ID) {
		t.Fatalf("broad root grant leaked other users through media index scopes: %v %v", mediaScopes, err)
	}
	if _, err := store.SearchRootsRoot(firstSession, rootID, otherPath); !errors.Is(err, ErrForbidden) {
		t.Fatalf("broad grant allowed search inside another user's home: %v", err)
	}
	myPath := fmt.Sprintf("Users/u%d/photos/family.jpg", first.ID)
	if !store.CanAccessRoot(firstSession, rootID, myPath, true, false) {
		t.Fatal("privacy guard blocked user's own private folder")
	}
}

func (s *Store) userIDForStorageTest(t *testing.T, session string) int64 {
	t.Helper()
	user, ok := s.Identity(session)
	if !ok {
		t.Fatal("session expired")
	}
	return user.ID
}

func TestPersonalStoragePerCategoryRootBindingsCannotBeSilentlyMoved(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "owner-password-for-storage-2026"); err != nil {
		t.Fatal(err)
	}
	admin, _ := store.Login("owner", "owner-password-for-storage-2026")
	u, err := store.CreateUser(admin, "person", "person-password-for-storage-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	other, err := store.CreateUser(admin, "other", "other-password-for-storage-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	const rootA = "0123456789abcdef0123456789abcdef"
	const rootB = "fedcba9876543210fedcba9876543210"
	files, err := store.AssignUserStorage(admin, u.ID, StorageFiles, rootA, 1)
	if err != nil {
		t.Fatal(err)
	}
	photos, err := store.AssignUserStorage(admin, u.ID, StoragePhotos, rootB, 2)
	if err != nil {
		t.Fatal(err)
	}
	if files.RelativePath != "Users/u2/files" || photos.RootID != rootB || photos.RelativePath != "Users/u2/photos" {
		t.Fatalf("wrong fixed user storage paths: files=%+v photos=%+v", files, photos)
	}
	if _, err := store.AssignUserStorage(admin, other.ID, StorageFiles, rootA, 1); err != nil {
		t.Fatal(err)
	}
	if _, err := store.AssignUserStorage(admin, u.ID, StorageFiles, rootB, 2); !errors.Is(err, ErrStorageReassignmentRequiresMigration) {
		t.Fatalf("silently rebound personal files to another physical disk: %v", err)
	}
	if _, err := store.AssignUserStorage(admin, u.ID, StorageFiles, rootA, 2); !errors.Is(err, ErrStorageReassignmentRequiresMigration) {
		t.Fatalf("silently accepted root generation change: %v", err)
	}
	if _, err := store.AssignUserStorage(admin, u.ID, StorageFiles, rootA, 1); err != nil {
		t.Fatal(err)
	}
	if _, err := store.AssignUserStorage(admin, u.ID, "anything", rootA, 1); !errors.Is(err, ErrInput) {
		t.Fatalf("invalid category accepted: %v", err)
	}
	memberSession, _ := store.Login("person", "person-password-for-storage-2026")
	if _, err := store.AssignUserStorage(memberSession, u.ID, StorageVideos, rootA, 1); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member assigned its own disk: %v", err)
	}
	policy, err := store.StoragePolicy(admin, u.ID)
	if err != nil || len(policy.Locations) != 2 {
		t.Fatalf("missing category bindings: %+v %v", policy, err)
	}
}
