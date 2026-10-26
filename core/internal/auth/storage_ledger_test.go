package auth

import (
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"testing"
)

func TestStorageLedgerReservationsAcrossRootsAndRestart(t *testing.T) {
	file := filepath.Join(t.TempDir(), "accounts.sqlite")
	s, err := Open(file)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Setup("owner", "owner-storage-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := s.Login("owner", "owner-storage-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := s.CreateUser(admin, "member", "member-storage-password-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	session, err := s.Login("member", "member-storage-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	const rootA = "11111111111111111111111111111111"
	const rootB = "22222222222222222222222222222222"
	if _, err := s.AssignUserStorage(admin, member.ID, StorageFiles, rootA, 1); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AssignUserStorage(admin, member.ID, StoragePhotos, rootB, 2); err != nil {
		t.Fatal(err)
	}
	if err := s.SetUserStorageQuota(admin, member.ID, 100); err != nil {
		t.Fatal(err)
	}
	id, managed, err := s.ReserveStorageUpload(session, rootA, 1, fmt.Sprintf("Users/u%d/files/one.txt", member.ID), 70)
	if err != nil || !managed {
		t.Fatalf("reserve: %q %v %v", id, managed, err)
	}
	if _, _, err := s.ReserveStorageUpload(session, rootB, 2, fmt.Sprintf("Users/u%d/photos/two.jpg", member.ID), 31); !errors.Is(err, ErrStorageQuotaExceeded) {
		t.Fatalf("cross root limit bypass: %v", err)
	}
	meter, err := s.StorageMeter(session, member.ID)
	if err != nil || meter.UsedBytes != 0 || meter.ReservedBytes != 70 || meter.AvailableBytes == nil || *meter.AvailableBytes != 30 {
		t.Fatalf("unexpected reservation meter: %+v %v", meter, err)
	}
	if err := s.LinkStorageUpload(id, "33333333333333333333333333333333"); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(file)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	loaded, err := s.ReservationForUpload("33333333333333333333333333333333", session)
	if err != nil || loaded != id {
		t.Fatalf("restarted reservation was lost: %s %v", loaded, err)
	}
	if err := s.CommitStorageReservation(id); err != nil {
		t.Fatal(err)
	}
	if err := s.CommitStorageReservation(id); !errors.Is(err, ErrStorageReservationMissing) {
		t.Fatalf("double credited reservation: %v", err)
	}
	meter, err = s.StorageMeter(admin, member.ID)
	if err != nil || meter.UsedBytes != 70 || meter.ReservedBytes != 0 {
		t.Fatalf("commit meter: %+v %v", meter, err)
	}
	second, managed, err := s.ReserveStorageUpload(session, rootB, 2, fmt.Sprintf("Users/u%d/photos/two.jpg", member.ID), 30)
	if err != nil || !managed {
		t.Fatalf("could not allocate remaining bytes: %v", err)
	}
	if err := s.ReleaseStorageReservation(second); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.ReserveStorageUpload(session, rootB, 2, fmt.Sprintf("Users/u%d/photos/oversize.jpg", member.ID), 31); !errors.Is(err, ErrStorageQuotaExceeded) {
		t.Fatalf("exceeded committed quota: %v", err)
	}
	if _, _, err := s.ReserveStorageUpload(session, rootA, 1, fmt.Sprintf("Users/u%d/files/one.txt", member.ID), 1); !errors.Is(err, ErrStorageLedgerConflict) {
		t.Fatalf("allowed a second publication to replace already recorded destination: %v", err)
	}
	if _, _, err := s.ReserveStorageUpload(session, rootA, 2, fmt.Sprintf("Users/u%d/files/not-this-generation.txt", member.ID), 1); !errors.Is(err, ErrStorageUnassigned) {
		t.Fatalf("accepted stale root generation: %v", err)
	}
	for _, name := range []string{
		fmt.Sprintf("users/u%d/files/case-escape.txt", member.ID),
		fmt.Sprintf("USERS/u%d/files/case-escape.txt", member.ID),
	} {
		if _, tracked, err := s.ReserveStorageUpload(session, rootA, 1, name, 1); tracked || !errors.Is(err, ErrStorageUnassigned) {
			t.Fatalf("APFS case-variant bypassed quota for %q: tracked=%v err=%v", name, tracked, err)
		}
	}
	if _, _, err := s.ReserveStorageUpload(session, rootA, 1, fmt.Sprintf("Users/u%d/files/../another-user.txt", member.ID), 1); !errors.Is(err, ErrInput) {
		t.Fatalf("accepted unsafe noncanonical path: %v", err)
	}
	if err := s.SetUserStorageQuota(admin, member.ID, 50); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.ReserveStorageUpload(session, rootB, 2, fmt.Sprintf("Users/u%d/photos/new.jpg", member.ID), 1); !errors.Is(err, ErrStorageQuotaExceeded) {
		t.Fatalf("shrinking quota below used permitted new write: %v", err)
	}
	if err := s.ForgetPermanentlyDeletedStorage(rootA, 1, fmt.Sprintf("Users/u%d/files/one.txt", member.ID)); err != nil {
		t.Fatal(err)
	}
	meter, err = s.StorageMeter(session, member.ID)
	if err != nil || meter.UsedBytes != 0 {
		t.Fatalf("purged bytes not released: %+v %v", meter, err)
	}
	if err := s.ForgetPermanentlyDeletedStorage(rootA, 1, "Users"); err != nil {
		t.Fatal(err)
	}
}

func TestStorageLedgerConcurrentAllocationsDoNotOversubscribe(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Setup("owner", "owner-storage-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, _ := s.Login("owner", "owner-storage-password-2026")
	member, err := s.CreateUser(admin, "person", "person-storage-password-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	session, _ := s.Login("person", "person-storage-password-2026")
	root := "11111111111111111111111111111111"
	if _, err := s.AssignUserStorage(admin, member.ID, StorageFiles, root, 1); err != nil {
		t.Fatal(err)
	}
	if err := s.SetUserStorageQuota(admin, member.ID, 100); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	var mu sync.Mutex
	ids := []string{}
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			id, ok, err := s.ReserveStorageUpload(session, root, 1, fmt.Sprintf("Users/u%d/files/%d.bin", member.ID, i), 30)
			if err == nil && ok {
				mu.Lock()
				ids = append(ids, id)
				mu.Unlock()
				return
			}
			if !errors.Is(err, ErrStorageQuotaExceeded) {
				t.Errorf("unexpected concurrent reserve result: %v", err)
			}
		}(i)
	}
	wg.Wait()
	if len(ids) != 3 {
		t.Fatalf("accepted %d concurrent 30-byte uploads under 100-byte quota", len(ids))
	}
	meter, err := s.StorageMeter(session, member.ID)
	if err != nil || meter.ReservedBytes != 90 {
		t.Fatalf("wrong concurrent budget: %+v %v", meter, err)
	}
}
