package auth

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSyncVerifiedRootGenerationPreservesPersonalStorageAndInvalidatesShares(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Setup("owner", "owner-rebind-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := s.Login("owner", "owner-rebind-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := s.CreateUser(admin, "family", "family-rebind-password-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberSession, err := s.Login("family", "family-rebind-password-2026")
	if err != nil {
		t.Fatal(err)
	}

	const rootID = "11111111111111111111111111111111"
	quota := int64(50 << 20)
	if _, err := s.AllocateUserStorageRoot(admin, adminUserID(t, s), rootID, 1, nil, []string{StorageFiles, StoragePhotos, StorageVideos}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AllocateUserStorageRoot(admin, member.ID, rootID, 1, &quota, []string{StorageFiles, StoragePhotos}); err != nil {
		t.Fatal(err)
	}

	resID, managed, err := s.ReserveStorageUpload(memberSession, rootID, 1, fmt.Sprintf("Users/u%d/files/doc.txt", member.ID), 1024)
	if err != nil || !managed {
		t.Fatalf("reserve upload: %q %v %v", resID, managed, err)
	}
	ident := strings.Repeat("a", 64)
	if err := s.CommitStorageReservationWithIdentity(resID, ident); err != nil {
		t.Fatal(err)
	}
	pendingID, managed, err := s.ReserveStorageUpload(memberSession, rootID, 1, fmt.Sprintf("Users/u%d/files/inflight.bin", member.ID), 2048)
	if err != nil || !managed || pendingID == "" {
		t.Fatalf("reserve pending upload: %q %v %v", pendingID, managed, err)
	}
	if _, err := s.ShareFolderAlbum(admin, rootID, 1, "Trip", "Trip", member.ID, false); err != nil {
		t.Fatalf("share folder album: %v", err)
	}
	_, shareToken, err := s.CreateRootFileShare(
		context.Background(),
		memberSession,
		rootID,
		1,
		fmt.Sprintf("Users/u%d/files/doc.txt", member.ID),
		"fp-doc",
		"file",
		time.Now().Add(time.Hour).Unix(),
		SharePolicy{},
	)
	if err != nil || shareToken == "" {
		t.Fatalf("create root share: %v", err)
	}

	if err := s.SyncVerifiedRootGeneration(rootID, 2); err != nil {
		t.Fatalf("SyncVerifiedRootGeneration: %v", err)
	}
	// Idempotent repeat call must be a clean no-op.
	if err := s.SyncVerifiedRootGeneration(rootID, 2); err != nil {
		t.Fatalf("repeat SyncVerifiedRootGeneration: %v", err)
	}

	policy, err := s.StoragePolicy(memberSession, member.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, loc := range policy.Locations {
		if loc.RootGeneration != 2 {
			t.Fatalf("location %+v remained at old generation", loc)
		}
	}
	if len(policy.RootQuotas) != 1 || policy.RootQuotas[0].RootGeneration != 2 || policy.RootQuotas[0].QuotaBytes == nil || *policy.RootQuotas[0].QuotaBytes != quota {
		t.Fatalf("unexpected root quotas after sync: %+v", policy.RootQuotas)
	}
	gotIdent, err := s.StorageFileIdentity(rootID, 2, fmt.Sprintf("Users/u%d/files/doc.txt", member.ID))
	if err != nil || gotIdent != ident {
		t.Fatalf("cascaded file identity missing on generation 2: %q %v", gotIdent, err)
	}
	hasPending, err := s.HasPendingCategoryReservations(member.ID, rootID, 2, fmt.Sprintf("Users/u%d/files", member.ID))
	if err != nil || !hasPending {
		t.Fatalf("pending reservation did not advance to generation 2: %v %v", hasPending, err)
	}
	targets, err := s.FolderAlbumShareTargets(admin, rootID, 2)
	if err != nil || len(targets) != 1 || targets[0].UserID != member.ID {
		t.Fatalf("folder album targets on generation 2: %+v %v", targets, err)
	}
	var shareGen int64
	if err := s.db.QueryRow("SELECT root_generation FROM root_file_shares WHERE root_id=?", rootID).Scan(&shareGen); err != nil || shareGen != 1 {
		t.Fatalf("root_file_shares should remain pinned to generation 1, got %d (%v)", shareGen, err)
	}
}

func TestStorageSwitchRoundTripClearsDetachedPath(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Setup("owner", "owner-roundtrip-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := s.Login("owner", "owner-roundtrip-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := s.CreateUser(admin, "family", "family-roundtrip-password-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberSession, err := s.Login("family", "family-roundtrip-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	const rootA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const rootB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	if _, err := s.AssignUserStorage(admin, member.ID, StorageFiles, rootA, 1); err != nil {
		t.Fatal(err)
	}
	prefix := fmt.Sprintf("Users/u%d/files", member.ID)

	switchOnce := func(taskID, src, dst string) {
		t.Helper()
		if _, err := s.db.Exec(`INSERT INTO storage_switch_tasks(id,user_id,request,progress,committed,created_at) VALUES(?,?,x'7b7d',x'7b7d',0,1)`,
			taskID, member.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := s.db.Exec(`INSERT INTO user_storage_reservations(id,user_id,root_id,root_generation,relative_path,size_bytes,upload_id,created_at) VALUES(?,?,?,?,?,0,NULL,1)`,
			taskID, member.ID, dst, 1, ".lightisle-switch-"+taskID); err != nil {
			t.Fatal(err)
		}
		if _, err := s.SwitchUserStorageCategories(admin, SwitchUserStorageCategoriesRequest{
			TargetUserID:     member.ID,
			Categories:       []string{StorageFiles},
			SourceRootID:     src,
			SourceGeneration: 1,
			TargetRootID:     dst,
			TargetGeneration: 1,
			TaskID:           taskID,
		}); err != nil {
			t.Fatalf("switch %s -> %s: %v", src, dst, err)
		}
	}

	switchOnce("task-a-to-b", rootA, rootB)
	if s.CanAccessRoot(memberSession, rootA, prefix, false, false) {
		t.Fatal("detached rootA remained accessible to member")
	}
	switchOnce("task-b-to-a", rootB, rootA)
	if !s.CanAccessRoot(memberSession, rootA, prefix, true, false) {
		t.Fatal("round-trip switch back to rootA failed to restore member access")
	}
	var detachedCount int
	if err := s.db.QueryRow("SELECT COUNT(*) FROM user_storage_detached_paths WHERE root_id=?", rootA).Scan(&detachedCount); err != nil || detachedCount != 0 {
		t.Fatalf("expected detached path on rootA to be cleared, got count=%d err=%v", detachedCount, err)
	}
}

func adminUserID(t *testing.T, s *Store) int64 {
	t.Helper()
	users, err := s.NativeListUsers()
	if err != nil {
		t.Fatal(err)
	}
	for _, u := range users {
		if u.Role == RoleAdmin {
			return u.ID
		}
	}
	t.Fatal("admin user not found")
	return 0
}
