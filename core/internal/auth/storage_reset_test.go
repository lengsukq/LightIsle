package auth

import (
	"errors"
	"fmt"
	"path/filepath"
	"testing"
)

func TestAbandonUserStorageLocationOnlyClearsSelectedCategory(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("admin", "admin-storage-pass-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := store.Login("admin", "admin-storage-pass-2026")
	if err != nil {
		t.Fatal(err)
	}
	user, err := store.CreateUser(admin, "member", "member-storage-pass-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	member, err := store.Login("member", "member-storage-pass-2026")
	if err != nil {
		t.Fatal(err)
	}
	const oldRoot = "11111111111111111111111111111111"
	const newRoot = "22222222222222222222222222222222"
	for _, category := range []string{StorageFiles, StoragePhotos} {
		if _, err := store.AssignUserStorage(admin, user.ID, category, oldRoot, 1); err != nil {
			t.Fatal(err)
		}
	}
	file := fmt.Sprintf("Users/u%d/files/file.dat", user.ID)
	photo := fmt.Sprintf("Users/u%d/photos/image.jpg", user.ID)
	committed, tracked, err := store.ReserveStorageUpload(member, oldRoot, 1, file, 10)
	if err != nil || !tracked {
		t.Fatalf("file reservation: %s %v %v", committed, tracked, err)
	}
	if err := store.CommitStorageReservation(committed); err != nil {
		t.Fatal(err)
	}
	photoReservation, tracked, err := store.ReserveStorageUpload(member, oldRoot, 1, photo, 7)
	if err != nil || !tracked {
		t.Fatalf("photo reservation: %s %v %v", photoReservation, tracked, err)
	}
	if err := store.AbandonUserStorageLocation(member, user.ID, StorageFiles, oldRoot, 1); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member abandoned account location: %v", err)
	}
	if err := store.AbandonUserStorageLocation(admin, user.ID, StorageFiles, newRoot, 1); !errors.Is(err, ErrStorageReassignmentRequiresMigration) {
		t.Fatalf("mismatched physical root accepted: %v", err)
	}
	if err := store.AbandonUserStorageLocation(admin, user.ID, StorageFiles, oldRoot, 2); !errors.Is(err, ErrStorageReassignmentRequiresMigration) {
		t.Fatalf("stale generation accepted: %v", err)
	}
	if err := store.AbandonUserStorageLocation(admin, user.ID, StorageFiles, oldRoot, 1); err != nil {
		t.Fatal(err)
	}
	if err := store.AbandonUserStorageLocation(admin, user.ID, StorageFiles, oldRoot, 1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("stale repeat abandonment unexpectedly succeeded: %v", err)
	}
	policy, err := store.StoragePolicy(admin, user.ID)
	if err != nil || len(policy.Locations) != 1 || policy.Locations[0].Category != StoragePhotos || policy.AccountedBytes != 0 || policy.ReservedBytes != 7 {
		t.Fatalf("category isolation or accounting: %+v err=%v", policy, err)
	}
	if store.CanAccessRoot(member, oldRoot, fmt.Sprintf("Users/u%d/files/secret", user.ID), true, false) {
		t.Fatal("abandoned category inherited old access")
	}
	if !store.CanAccessRoot(member, oldRoot, fmt.Sprintf("Users/u%d/photos/a.jpg", user.ID), true, false) {
		t.Fatal("reset affected unrelated category")
	}
	if _, err := store.AssignUserStorage(admin, user.ID, StorageFiles, newRoot, 2); err != nil {
		t.Fatalf("could not create a new empty storage location: %v", err)
	}
	policy, err = store.StoragePolicy(admin, user.ID)
	if err != nil || len(policy.Locations) != 2 {
		t.Fatalf("new storage binding not saved: %+v %v", policy, err)
	}
	if _, tracked, err := store.ReserveStorageUpload(member, newRoot, 2, fmt.Sprintf("Users/u%d/files/new.dat", user.ID), 1); err != nil || !tracked {
		t.Fatalf("new location could not reserve capacity: %v %v", tracked, err)
	}
}
