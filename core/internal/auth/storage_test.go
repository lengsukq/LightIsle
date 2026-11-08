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
	const rootID = "11111111111111111111111111111111"
	if _, err := store.AssignUserStorage(admin, member.ID, StorageFiles, rootID, 3); err != nil {
		t.Fatal(err)
	}

	ownerID := store.userIDForStorageTest(t, admin)
	ownerPolicy, err := store.StoragePolicy(admin, ownerID)
	if err != nil || ownerPolicy.QuotaBytes != nil {
		t.Fatalf("admin should have unlimited app quota: %+v %v", ownerPolicy, err)
	}
	defaultPolicy, err := store.StoragePolicy(memberSession, member.ID)
	if err != nil || defaultPolicy.QuotaBytes != nil || len(defaultPolicy.RootQuotas) != 1 ||
		defaultPolicy.RootQuotas[0].QuotaBytes == nil ||
		*defaultPolicy.RootQuotas[0].QuotaBytes != DefaultMemberQuotaBytes ||
		defaultPolicy.Enforcement != "pending" {
		t.Fatalf("new member should show per-disk 100GiB without a total: %+v %v", defaultPolicy, err)
	}
	if _, err := store.StoragePolicy(memberSession, ownerID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member can inspect another user's storage: %v", err)
	}
	if err := store.SetUserStorageRootQuota(memberSession, member.ID, rootID, 3, 20<<30); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member changed its own quota: %v", err)
	}
	if err := store.SetUserStorageRootQuota(admin, ownerID, rootID, 3, 5<<30); !errors.Is(err, ErrForbidden) {
		t.Fatalf("owner admin quota should not be configurable: %v", err)
	}
	if err := store.SetUserStorageRootQuota(admin, member.ID, rootID, 3, MaxMemberQuotaBytes+1); !errors.Is(err, ErrInput) {
		t.Fatalf("accepted impossible quota: %v", err)
	}
	if err := store.SetUserStorageRootQuota(admin, member.ID, rootID, 3, 20<<30); err != nil {
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
	if err != nil || len(policy.RootQuotas) != 1 || policy.RootQuotas[0].QuotaBytes == nil ||
		*policy.RootQuotas[0].QuotaBytes != 20<<30 {
		t.Fatalf("custom quota did not survive restart: %+v %v", policy, err)
	}
	if err := store.SetEnabled(admin, member.ID, false); err != nil {
		t.Fatal(err)
	}
	if err := store.SetUserStorageRootQuota(memberSession, member.ID, rootID, 3, 25<<30); !errors.Is(err, ErrForbidden) {
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

func TestAllocateStorageRootQuotaFirstThenAddCategoriesAndModifyQuota(t *testing.T) {
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
	const rootA = "0123456789abcdef0123456789abcdef"
	initialQuota := int64(250 << 30)

	// 1. Allocate disk space and quota first with 0 categories.
	locs, err := store.AllocateUserStorageRoot(admin, u.ID, rootA, 1, &initialQuota, nil)
	if err != nil || len(locs) != 0 {
		t.Fatalf("allocate quota-only root failed: locs=%+v err=%v", locs, err)
	}
	policy, err := store.StoragePolicy(admin, u.ID)
	if err != nil || len(policy.Locations) != 0 || len(policy.RootQuotas) != 1 ||
		policy.RootQuotas[0].QuotaBytes == nil || *policy.RootQuotas[0].QuotaBytes != initialQuota {
		t.Fatalf("expected 250GiB root quota before categories: %+v %v", policy, err)
	}

	// 2. Freely modify quota while 0 categories are bound.
	if err := store.SetUserStorageRootQuota(admin, u.ID, rootA, 1, 300<<30); err != nil {
		t.Fatalf("modify quota on 0-category root failed: %v", err)
	}

	// 3. Add a category directory later without specifying quotaBytes; existing 300GiB quota must be preserved.
	if _, err := store.AssignUserStorage(admin, u.ID, StorageFiles, rootA, 1); err != nil {
		t.Fatalf("add files category later failed: %v", err)
	}
	policy, err = store.StoragePolicy(admin, u.ID)
	if err != nil || len(policy.Locations) != 1 || len(policy.RootQuotas) != 1 ||
		policy.RootQuotas[0].QuotaBytes == nil || *policy.RootQuotas[0].QuotaBytes != 300<<30 {
		t.Fatalf("adding category later overwrote custom quota: %+v %v", policy, err)
	}

	// 4. Add remaining categories via AllocateUserStorageRoot and simultaneously update quota to 500GiB.
	updatedQuota := int64(500 << 30)
	locs, err = store.AllocateUserStorageRoot(admin, u.ID, rootA, 1, &updatedQuota, []string{StoragePhotos, StorageVideos})
	if err != nil || len(locs) != 2 {
		t.Fatalf("add photos+videos with quota update failed: locs=%+v err=%v", locs, err)
	}
	policy, err = store.StoragePolicy(admin, u.ID)
	if err != nil || len(policy.Locations) != 3 || len(policy.RootQuotas) != 1 ||
		policy.RootQuotas[0].QuotaBytes == nil || *policy.RootQuotas[0].QuotaBytes != updatedQuota {
		t.Fatalf("expected 3 categories and 500GiB quota: %+v %v", policy, err)
	}

	// 5. Retire the entire root generation when removed.
	if err := store.AbandonUserStorageRoot(admin, u.ID, rootA, 1); err != nil {
		t.Fatalf("abandon root failed: %v", err)
	}
	policy, err = store.StoragePolicy(admin, u.ID)
	if err != nil || len(policy.Locations) != 0 || len(policy.RootQuotas) != 0 {
		t.Fatalf("expected empty policy after abandoning root: %+v %v", policy, err)
	}
}
