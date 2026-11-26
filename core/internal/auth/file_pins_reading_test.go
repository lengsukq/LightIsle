package auth

import (
	"errors"
	"fmt"
	"math"
	"path/filepath"
	"strings"
	"testing"
)

func TestFilePinsAndReadingProgress(t *testing.T) {
	st, adminTok, memberTok := openReminderTestStore(t)
	const rootID = "abcdef0123456789abcdef0123456789"
	const gen uint64 = 2

	pin, err := st.UpsertFilePin(memberTok, rootID, gen, "Docs/Notes", "folder", "我的笔记")
	if err != nil || pin.Label != "我的笔记" || pin.Kind != "folder" {
		t.Fatalf("UpsertFilePin: %+v err=%v", pin, err)
	}
	// Isolated per user: admin sees 0 pins.
	adminPins, err := st.ListFilePins(adminTok, rootID, gen)
	if err != nil || len(adminPins) != 0 {
		t.Fatalf("expected 0 admin pins, got %+v err=%v", adminPins, err)
	}
	memberPins, err := st.ListFilePins(memberTok, rootID, gen)
	if err != nil || len(memberPins) != 1 || memberPins[0].Path != "Docs/Notes" {
		t.Fatalf("expected 1 member pin, got %+v err=%v", memberPins, err)
	}
	if err := st.DeleteFilePin(memberTok, rootID, gen, "Docs/Notes"); err != nil {
		t.Fatal(err)
	}
	memberPins, err = st.ListFilePins(memberTok, rootID, gen)
	if err != nil || len(memberPins) != 0 {
		t.Fatalf("expected 0 pins after delete, got %+v", memberPins)
	}

	// Reading progress upsert, get, list, validation.
	if _, err := st.UpsertReadingProgress(memberTok, rootID, gen, "Books/a.epub", "ch1", 101); !errors.Is(err, ErrInput) {
		t.Fatalf("percent > 100 must fail, got %v", err)
	}
	if _, err := st.UpsertReadingProgress(memberTok, rootID, gen, "Books/a.epub", "ch1", math.NaN()); !errors.Is(err, ErrInput) {
		t.Fatalf("NaN percent must fail, got %v", err)
	}
	prog, err := st.UpsertReadingProgress(memberTok, rootID, gen, "Books/a.epub", "OEBPS/ch2.xhtml#p5", 42.5)
	if err != nil || prog.Percent != 42.5 || prog.Locator != "OEBPS/ch2.xhtml#p5" {
		t.Fatalf("UpsertReadingProgress: %+v err=%v", prog, err)
	}
	got, found, err := st.GetReadingProgress(memberTok, rootID, gen, "Books/a.epub")
	if err != nil || !found || got.Locator != "OEBPS/ch2.xhtml#p5" {
		t.Fatalf("GetReadingProgress: %+v found=%v err=%v", got, found, err)
	}
	list, err := st.ListReadingProgress(memberTok, rootID, gen, 10)
	if err != nil || len(list) != 1 {
		t.Fatalf("ListReadingProgress: %+v err=%v", list, err)
	}
}

func TestReserveAndCommitStorageTextUpdateDelta(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	if err := st.Setup("admin", "AdminPass123456!"); err != nil {
		t.Fatal(err)
	}
	adminTok, err := st.Login("admin", "AdminPass123456!")
	if err != nil {
		t.Fatal(err)
	}
	member, err := st.CreateUser(adminTok, "carol", "CarolPass123456!", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberTok, err := st.Login("carol", "CarolPass123456!")
	if err != nil {
		t.Fatal(err)
	}
	const rootID = "11112222333344445555666677778888"
	const gen uint64 = 1
	if _, err := st.AssignUserStorage(adminTok, member.ID, StorageFiles, rootID, gen); err != nil {
		t.Fatal(err)
	}
	if err := st.SetUserStorageRootQuota(adminTok, member.ID, rootID, gen, 200); err != nil {
		t.Fatal(err)
	}

	notePath := fmt.Sprintf("Users/u%d/files/note.md", member.ID)
	// Initial file 100 bytes uploaded.
	res0, tracked, err := st.ReserveStorageUpload(memberTok, rootID, gen, notePath, 100)
	if err != nil || !tracked {
		t.Fatalf("initial reserve: %v tracked=%v", err, tracked)
	}
	idA := strings.Repeat("a", 64)
	if err := st.CommitStorageReservationWithIdentity(res0, idA); err != nil {
		t.Fatal(err)
	}

	// Growing from 100 -> 250 bytes (delta +150 > remaining 100) MUST fail with ErrStorageQuotaExceeded.
	if _, _, err := st.ReserveStorageTextUpdate(memberTok, rootID, gen, notePath, 250); !errors.Is(err, ErrStorageQuotaExceeded) {
		t.Fatalf("expected ErrStorageQuotaExceeded for 100->250 under 200 quota, got %v", err)
	}

	// Growing from 100 -> 180 bytes (delta +80 <= remaining 100) succeeds!
	res1, tracked, err := st.ReserveStorageTextUpdate(memberTok, rootID, gen, notePath, 180)
	if err != nil || !tracked || res1 == "" {
		t.Fatalf("ReserveStorageTextUpdate 100->180: %v tracked=%v", err, tracked)
	}
	// Concurrent update to the same path must fail with ErrStorageLedgerConflict.
	if _, _, err := st.ReserveStorageTextUpdate(memberTok, rootID, gen, notePath, 190); !errors.Is(err, ErrStorageLedgerConflict) {
		t.Fatalf("expected ErrStorageLedgerConflict on concurrent edit, got %v", err)
	}
	idB := strings.Repeat("b", 64)
	if err := st.CommitStorageTextUpdate(res1, 180, idB); err != nil {
		t.Fatalf("CommitStorageTextUpdate: %v", err)
	}
	meter, err := st.StorageMeter(memberTok, member.ID)
	if err != nil || meter.UsedBytes != 180 || meter.ReservedBytes != 0 {
		t.Fatalf("after grow meter = %+v, want used=180 reserved=0", meter)
	}

	// Shrinking from 180 -> 40 bytes frees 140 bytes accurately.
	res2, tracked, err := st.ReserveStorageTextUpdate(memberTok, rootID, gen, notePath, 40)
	if err != nil || !tracked {
		t.Fatalf("ReserveStorageTextUpdate shrink: %v", err)
	}
	idC := strings.Repeat("c", 64)
	if err := st.CommitStorageTextUpdate(res2, 40, idC); err != nil {
		t.Fatalf("CommitStorageTextUpdate shrink: %v", err)
	}
	meter, err = st.StorageMeter(memberTok, member.ID)
	if err != nil || meter.UsedBytes != 40 || meter.ReservedBytes != 0 {
		t.Fatalf("after shrink meter = %+v, want used=40 reserved=0", meter)
	}
	gotID, err := st.StorageFileIdentity(rootID, gen, notePath)
	if err != nil || gotID != idC {
		t.Fatalf("StorageFileIdentity = %q, want %q", gotID, idC)
	}

	// Unmanaged shared path returns tracked=false.
	if res3, tracked, err := st.ReserveStorageTextUpdate(adminTok, rootID, gen, "Shared/readme.md", 500); err != nil || tracked || res3 != "" {
		t.Fatalf("unmanaged path should return tracked=false, got res=%q tracked=%v err=%v", res3, tracked, err)
	}
}
