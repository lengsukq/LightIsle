package backup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

// The fixture emulates a volume binding; it is not physical-disk acceptance.
type restoreJourneyProvider struct{}

func (restoreJourneyProvider) Capture(_ context.Context, name string) (storageidentity.Binding, error) {
	resolved, err := filepath.EvalSymlinks(name)
	if err != nil {
		return storageidentity.Binding{}, err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return storageidentity.Binding{}, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return storageidentity.Binding{}, errors.New("directory identity unavailable")
	}
	return storageidentity.Binding{Path: filepath.Clean(resolved), VolumeUUID: "12345678-1234-1234-1234-123456789abc",
		DirectoryID: stat.Ino, BirthSec: stat.Birthtimespec.Sec, BirthNsec: stat.Birthtimespec.Nsec, Generation: uint64(stat.Gen)}, nil
}

func (p restoreJourneyProvider) Verify(ctx context.Context, binding storageidentity.Binding) error {
	current, err := p.Capture(ctx, binding.Path)
	if err != nil {
		return err
	}
	if !storageidentity.Equal(current, binding) {
		return storageidentity.ErrMismatch
	}
	return nil
}

func TestPersonalConfigurationBackupRestoreAndRollbackJourney(t *testing.T) {
	dataDir, volume := t.TempDir(), t.TempDir()
	rootPath := filepath.Join(volume, "family")
	if err := os.Mkdir(rootPath, 0700); err != nil {
		t.Fatal(err)
	}
	secondPath := filepath.Join(volume, "photos")
	if err := os.Mkdir(secondPath, 0700); err != nil {
		t.Fatal(err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	backupDir, err := os.MkdirTemp(home, "lightisle-restore-journey-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(backupDir) })
	registry, err := roots.OpenWithProvider(dataDir, restoreJourneyProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	root, err := registry.Add(context.Background(), "Family", rootPath)
	if err != nil {
		t.Fatal(err)
	}
	secondRoot, err := registry.Add(context.Background(), "Photos", secondPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.SetDefault(context.Background(), root.ID, root.Generation); err != nil {
		t.Fatal(err)
	}
	lease, err := registry.Acquire(context.Background(), root.ID)
	if err != nil {
		t.Fatal(err)
	}
	manager, err := files.NewPinnedManager(lease.Root)
	if err != nil {
		t.Fatal(err)
	}
	accounts, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if err := accounts.Setup("owner", "restore-owner-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "restore-owner-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(admin, "member", "restore-member-password-2026", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberSession, err := accounts.Login("member", "restore-member-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	location, err := accounts.AssignUserStorage(admin, member.ID, auth.StorageFiles, root.ID, root.Generation)
	if err != nil {
		t.Fatal(err)
	}
	if err := accounts.SetRootGrant(admin, member.ID, root.ID, "family-shared", false); err != nil {
		t.Fatal(err)
	}
	if err := accounts.SetUserStorageRootQuota(admin, member.ID, root.ID, root.Generation, 100); err != nil {
		t.Fatal(err)
	}
	photoLocation, err := accounts.AssignUserStorage(admin, member.ID, auth.StoragePhotos, secondRoot.ID, secondRoot.Generation)
	if err != nil {
		t.Fatal(err)
	}
	if err := accounts.SetUserStorageRootQuota(admin, member.ID, secondRoot.ID, secondRoot.Generation, 50); err != nil {
		t.Fatal(err)
	}
	photo := photoLocation.RelativePath + "/kept.jpg"
	photoPath := filepath.Join(secondPath, filepath.FromSlash(photo))
	if err := os.MkdirAll(filepath.Dir(photoPath), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(photoPath, []byte("photo"), 0600); err != nil {
		t.Fatal(err)
	}
	photoInfo, err := os.Stat(photoPath)
	if err != nil {
		t.Fatal(err)
	}
	photoIdentity := files.MediaFileIdentity(photoInfo)
	if photoIdentity == "" {
		t.Fatal("fixture photo has no verifiable identity")
	}
	photoReservation, photoTracked, err := accounts.ReserveStorageUpload(memberSession, secondRoot.ID, secondRoot.Generation, photo, 5)
	if err != nil || !photoTracked {
		t.Fatalf("photo reserve: %v %v", photoTracked, err)
	}
	if err := accounts.CommitStorageReservationWithIdentity(photoReservation, photoIdentity); err != nil {
		t.Fatal(err)
	}
	file := location.RelativePath + "/kept.txt"
	full := filepath.Join(rootPath, filepath.FromSlash(file))
	if err := os.MkdirAll(filepath.Dir(full), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(full)
	if err != nil {
		t.Fatal(err)
	}
	identity := files.MediaFileIdentity(info)
	if identity == "" {
		t.Fatal("fixture file has no verifiable identity")
	}
	reservation, tracked, err := accounts.ReserveStorageUpload(memberSession, root.ID, root.Generation, file, 3)
	if err != nil || !tracked {
		t.Fatalf("reserve: %v %v", tracked, err)
	}
	if err := accounts.CommitStorageReservationWithIdentity(reservation, identity); err != nil {
		t.Fatal(err)
	}
	pending, tracked, err := accounts.ReserveStorageUpload(memberSession, root.ID, root.Generation, location.RelativePath+"/pending.dat", 4)
	if err != nil || !tracked || pending == "" {
		t.Fatalf("pending: %v %v", tracked, err)
	}
	library, err := gallery.OpenRootScoped(dataDir, manager, root.ID, gallery.Options{RootGeneration: root.Generation})
	if err != nil {
		t.Fatal(err)
	}
	album, err := library.CreatePrivateAlbum(member.ID, "Family memories")
	if err != nil {
		t.Fatal(err)
	}
	service := New(nil, dataDir)
	if err := service.ProtectDestinations(registry); err != nil {
		t.Fatal(err)
	}
	if err := service.StartMetadataBackup(backupDir); err != nil {
		t.Fatal(err)
	}
	snapshot := await(t, service)
	if snapshot.LastError != "" || snapshot.LastSnapshot == "" {
		t.Fatalf("backup: %+v", snapshot)
	}
	if result, err := VerifySnapshot(context.Background(), snapshot.LastSnapshot); err != nil || !result.Verified || result.Files != 0 {
		t.Fatalf("metadata verification: %+v %v", result, err)
	}
	if err := accounts.SetUserStorageRootQuota(admin, member.ID, root.ID, root.Generation, 10); err != nil {
		t.Fatal(err)
	}
	if _, err := library.RenamePrivateAlbum(member.ID, album.ID, "Changed after backup"); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(full, full+".preserved"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte("new"), 0600); err != nil {
		t.Fatal(err)
	}
	replacement, err := os.Stat(full)
	if err != nil || files.MediaFileIdentity(replacement) == "" || files.MediaFileIdentity(replacement) == identity {
		t.Fatalf("fixture failed to replace file identity: %v", err)
	}
	if err := service.StartMetadataRestore(snapshot.LastSnapshot); err != nil {
		t.Fatal(err)
	}
	staged := await(t, service)
	if staged.LastError != "" || staged.RestoredMetadata == "" {
		t.Fatalf("stage restore: %+v", staged)
	}
	stage := filepath.Base(staged.RestoredMetadata)
	service.Close()
	if err := library.Close(); err != nil {
		t.Fatal(err)
	}
	if err := accounts.Close(); err != nil {
		t.Fatal(err)
	}
	if err := manager.Close(); err != nil {
		t.Fatal(err)
	}
	if err := lease.Close(); err != nil {
		t.Fatal(err)
	}
	rollbackDir, err := ActivateStagedMetadata(dataDir, stage)
	if err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(full); err != nil || string(data) != "new" {
		t.Fatalf("original data overwritten: %q %v", data, err)
	}
	if data, err := os.ReadFile(photoPath); err != nil || string(data) != "photo" {
		t.Fatalf("second root data changed: %q %v", data, err)
	}

	restored, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	if restored.Session(admin) || restored.Session(memberSession) {
		t.Fatal("restored old session remained valid")
	}
	restoredAdmin, err := restored.Login("owner", "restore-owner-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	restoredMember, err := restored.Login("member", "restore-member-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	if !restored.CanAccessRoot(restoredMember, root.ID, "family-shared/picture.jpg", false, false) ||
		restored.CanAccessRoot(restoredMember, root.ID, "family-shared/picture.jpg", true, false) {
		t.Fatal("family read-only grant was not restored")
	}
	policy, err := restored.StoragePolicy(restoredAdmin, member.ID)
	var firstQuota, secondQuota *auth.StorageRootQuota
	for i := range policy.RootQuotas {
		q := &policy.RootQuotas[i]
		if q.RootID == root.ID && q.RootGeneration == root.Generation {
			firstQuota = q
		}
		if q.RootID == secondRoot.ID && q.RootGeneration == secondRoot.Generation {
			secondQuota = q
		}
	}
	if err != nil || len(policy.RootQuotas) != 2 || firstQuota == nil || firstQuota.QuotaBytes == nil || *firstQuota.QuotaBytes != 100 ||
		firstQuota.AccountedBytes != 3 || firstQuota.ReservedBytes != 4 || secondQuota == nil || secondQuota.QuotaBytes == nil ||
		*secondQuota.QuotaBytes != 50 || secondQuota.AccountedBytes != 5 || secondQuota.ReservedBytes != 0 || policy.Enforcement != "pending" {
		t.Fatalf("restored quota or pending state: %+v %v", policy, err)
	}
	if got, err := restored.StorageFileIdentity(root.ID, root.Generation, file); err != nil || got != identity {
		t.Fatalf("file identity record not restored: %q %v", got, err)
	}
	if current, err := os.Stat(full); err != nil || files.MediaFileIdentity(current) == identity {
		t.Fatalf("newer file was incorrectly identified as the restored ledger object: %v", err)
	}
	if data, err := os.ReadFile(full + ".preserved"); err != nil || string(data) != "old" {
		t.Fatalf("prior file was changed during configuration restore: %q %v", data, err)
	}
	if got, err := restored.StorageFileIdentity(secondRoot.ID, secondRoot.Generation, photo); err != nil || got != photoIdentity {
		t.Fatalf("second root identity not restored: %q %v", got, err)
	}
	if _, err := os.Stat(filepath.Join(snapshot.LastSnapshot, "data")); !os.IsNotExist(err) {
		t.Fatalf("snapshot unexpectedly contains originals: %v", err)
	}
	restoredRegistry, err := roots.OpenWithProvider(dataDir, restoreJourneyProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	selected, ok := restoredRegistry.Default()
	if !ok || selected.ID != root.ID || selected.Generation != root.Generation {
		t.Fatalf("root identity changed: %+v", selected)
	}
	secondLease, err := restoredRegistry.Acquire(context.Background(), secondRoot.ID)
	if err != nil {
		t.Fatalf("second root not restored: %v", err)
	}
	if err := secondLease.Close(); err != nil {
		t.Fatal(err)
	}
	restoredLease, err := restoredRegistry.Acquire(context.Background(), root.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer restoredLease.Close()
	restoredManager, err := files.NewPinnedManager(restoredLease.Root)
	if err != nil {
		t.Fatal(err)
	}
	defer restoredManager.Close()
	restoredLibrary, err := gallery.OpenRootScoped(dataDir, restoredManager, root.ID, gallery.Options{RootGeneration: root.Generation})
	if err != nil {
		t.Fatal(err)
	}
	defer restoredLibrary.Close()
	albums, err := restoredLibrary.PrivateAlbumsScoped(member.ID, []string{"."})
	if err != nil || len(albums) != 1 || !strings.EqualFold(albums[0].Name, "Family memories") {
		t.Fatalf("private album was not restored: %+v %v", albums, err)
	}
	if err := restoredLibrary.Close(); err != nil {
		t.Fatal(err)
	}
	if err := restoredManager.Close(); err != nil {
		t.Fatal(err)
	}
	if err := restoredLease.Close(); err != nil {
		t.Fatal(err)
	}
	if err := restored.Close(); err != nil {
		t.Fatal(err)
	}
	tx := strings.TrimPrefix(filepath.Base(rollbackDir), rollbackPrefix)
	if _, err := RollbackMetadata(dataDir, tx); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	if data, err := os.ReadFile(full); err != nil || string(data) != "new" {
		t.Fatalf("rollback altered original file: %q %v", data, err)
	}
	rolledBack, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer rolledBack.Close()
	if rolledBack.Session(restoredAdmin) || rolledBack.Session(restoredMember) {
		t.Fatal("rollback revived a session")
	}
	rolledBackAdmin, err := rolledBack.Login("owner", "restore-owner-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	policy, err = rolledBack.StoragePolicy(rolledBackAdmin, member.ID)
	firstQuota, secondQuota = nil, nil
	for i := range policy.RootQuotas {
		q := &policy.RootQuotas[i]
		if q.RootID == root.ID && q.RootGeneration == root.Generation {
			firstQuota = q
		}
		if q.RootID == secondRoot.ID && q.RootGeneration == secondRoot.Generation {
			secondQuota = q
		}
	}
	if err != nil || len(policy.RootQuotas) != 2 || firstQuota == nil || firstQuota.QuotaBytes == nil || *firstQuota.QuotaBytes != 10 ||
		secondQuota == nil || secondQuota.QuotaBytes == nil || *secondQuota.QuotaBytes != 50 {
		t.Fatalf("rollback did not restore pre-activation quota: %+v %v", policy, err)
	}
	rolledBackLease, err := restoredRegistry.Acquire(context.Background(), root.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer rolledBackLease.Close()
	rolledBackManager, err := files.NewPinnedManager(rolledBackLease.Root)
	if err != nil {
		t.Fatal(err)
	}
	defer rolledBackManager.Close()
	rolledBackLibrary, err := gallery.OpenRootScoped(dataDir, rolledBackManager, root.ID, gallery.Options{RootGeneration: root.Generation})
	if err != nil {
		t.Fatal(err)
	}
	defer rolledBackLibrary.Close()
	albums, err = rolledBackLibrary.PrivateAlbumsScoped(member.ID, []string{"."})
	if err != nil || len(albums) != 1 || albums[0].Name != "Changed after backup" {
		t.Fatalf("rollback did not restore pre-activation album: %+v %v", albums, err)
	}
	// Restored grants and quotas alone must never turn a same-path replacement
	// directory into the physical root recorded by the snapshot.
	detachedPath := secondPath + "-detached"
	if err := os.Rename(secondPath, detachedPath); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(secondPath, 0700); err != nil {
		t.Fatal(err)
	}
	if lease, err := restoredRegistry.Acquire(context.Background(), secondRoot.ID); err == nil {
		lease.Close()
		t.Fatal("same-path replacement inherited restored root identity")
	}
	if data, err := os.ReadFile(filepath.Join(detachedPath, filepath.FromSlash(photo))); err != nil || string(data) != "photo" {
		t.Fatalf("original root data changed during identity check: %q %v", data, err)
	}
	if _, err := os.Stat(photoPath); !os.IsNotExist(err) {
		t.Fatalf("replacement inherited old contents: %v", err)
	}
}
