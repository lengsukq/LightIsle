package auth

import (
	"errors"
	"fmt"
	"path/filepath"
	"testing"
)

func TestStoragePendingReservationsAreReadOnlyAndPaged(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Setup("owner", "storage-admin-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := s.Login("owner", "storage-admin-2026")
	if err != nil {
		t.Fatal(err)
	}
	user, err := s.CreateUser(admin, "member", "storage-member-2026", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	member, err := s.Login("member", "storage-member-2026")
	if err != nil {
		t.Fatal(err)
	}
	const root = "11111111111111111111111111111111"
	if _, err := s.AssignUserStorage(admin, user.ID, StorageFiles, root, 2); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		p := fmt.Sprintf("Users/u%d/files/pending-%d", user.ID, i)
		if _, tracked, err := s.ReserveStorageUpload(member, root, 2, p, int64(10+i)); err != nil || !tracked {
			t.Fatalf("seed %d: tracked=%v err=%v", i, tracked, err)
		}
	}
	if _, _, err := s.StoragePendingReservations(member, user.ID, "", 2); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member inspected recovery inventory: %v", err)
	}
	if _, _, err := s.StoragePendingReservations(admin, user.ID, "bad", 2); !errors.Is(err, ErrInput) {
		t.Fatalf("invalid cursor was accepted: %v", err)
	}
	page, cursor, err := s.StoragePendingReservations(admin, user.ID, "", 2)
	if err != nil || len(page) != 2 || cursor == "" {
		t.Fatalf("page1: %v %q %v", page, cursor, err)
	}
	second, next, err := s.StoragePendingReservations(admin, user.ID, cursor, 2)
	if err != nil || len(second) != 1 || next != "" {
		t.Fatalf("page2: %v %q %v", second, next, err)
	}
	for _, item := range append(page, second...) {
		if item.RootID != root || item.RootGeneration != 2 || item.ID == "" || item.SizeBytes < 10 {
			t.Fatalf("corrupt recovery item: %+v", item)
		}
	}
	meter, err := s.StorageMeter(admin, user.ID)
	if err != nil || meter.UsedBytes != 0 || meter.ReservedBytes != 33 {
		t.Fatalf("recovery listing mutated ledger: %+v %v", meter, err)
	}
}
