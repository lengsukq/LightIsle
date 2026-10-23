package files

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"testing"
	"time"
)

func TestUploadMaintenanceListsWithoutRepairAndCleansOnlyEligibleExpiredState(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	stale, err := s.BeginUpload("stale.bin", 8, 42)
	if err != nil {
		t.Fatal(err)
	}
	stale, err = s.AppendUpload(stale.ID, stale.Owner, 0, bytes.NewReader([]byte("part")))
	if err != nil {
		t.Fatal(err)
	}
	stale.Activity = time.Now().Add(-8 * 24 * time.Hour).Unix()
	if _, err := s.persistUpload(stale); err != nil {
		t.Fatal(err)
	}

	recent, err := s.BeginUpload("recent.bin", 8, 43)
	if err != nil {
		t.Fatal(err)
	}
	partPath := path.Join(uploadsDir, recent.ID+".part")
	part, err := s.root.OpenFile(partPath, os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write([]byte("tail")); err != nil {
		t.Fatal(err)
	}
	if err := part.Close(); err != nil {
		t.Fatal(err)
	}

	published := beginPublishedUpload(t, s, "published.bin", 44, "done")
	published.Activity = time.Now().Add(-8 * 24 * time.Hour).Unix()
	if _, err := s.persistUpload(published); err != nil {
		t.Fatal(err)
	}

	partOnlyID := randomName()
	partOnlyPath := path.Join(uploadsDir, partOnlyID+".part")
	partOnly, err := s.root.OpenFile(partOnlyPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := partOnly.Write([]byte("orphan")); err != nil {
		t.Fatal(err)
	}
	if err := partOnly.Close(); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-8 * 24 * time.Hour)
	if err := os.Chtimes(filepath.Join(s.root.Name(), filepath.FromSlash(partOnlyPath)), old, old); err != nil {
		t.Fatal(err)
	}

	page, next, err := s.ListUploads("", 2)
	if err != nil || len(page) != 2 || next == "" {
		t.Fatalf("first upload page: rows=%+v next=%q err=%v", page, next, err)
	}
	second, next, err := s.ListUploads(next, 2)
	if err != nil || len(second) != 2 || next != "" {
		t.Fatalf("second upload page: rows=%+v next=%q err=%v", second, next, err)
	}
	var listedRecent *UploadRecord
	for _, record := range append(page, second...) {
		if record.State.ID == recent.ID {
			listedRecent = &record
		}
	}
	if listedRecent == nil || listedRecent.State.Offset != 0 || listedRecent.PartSize != 4 || listedRecent.State.Activity != recent.Activity {
		t.Fatalf("list did not expose committed state without repairing bytes: %+v", listedRecent)
	}
	partInfo, err := s.root.Stat(partPath)
	if err != nil || partInfo.Size() != 4 {
		t.Fatalf("listing modified staged bytes: info=%v err=%v", partInfo, err)
	}

	cutoff := time.Now().Add(-7 * 24 * time.Hour).Unix()
	removed, skipped, more, err := s.CleanupExpiredUploads(cutoff)
	if err != nil || len(removed) != 2 || skipped != 1 || more {
		t.Fatalf("cleanup report: removed=%v skipped=%d more=%v err=%v", removed, skipped, more, err)
	}
	removedIDs := map[string]bool{}
	for _, id := range removed {
		removedIDs[id] = true
	}
	if !removedIDs[stale.ID] || !removedIDs[partOnlyID] {
		t.Fatalf("cleanup removed wrong sessions: %v", removedIDs)
	}
	if _, err := s.UploadInfo(recent.ID, recent.Owner); err != nil {
		t.Fatalf("recent session was removed: %v", err)
	}
	if _, err := s.UploadInfo(published.ID, published.Owner); err != nil {
		t.Fatalf("published recovery journal was removed: %v", err)
	}
	if data, err := s.root.ReadFile("published.bin"); err != nil || string(data) != "done" {
		t.Fatalf("published destination changed during expiry cleanup: %q %v", data, err)
	}

	if err := s.CancelUpload(published.ID); err != nil {
		t.Fatalf("explicitly cancel published journal: %v", err)
	}
	if data, err := s.root.ReadFile("published.bin"); err != nil || string(data) != "done" {
		t.Fatalf("published destination changed during explicit cancellation: %q %v", data, err)
	}
	if _, err := s.UploadInfo(published.ID, published.Owner); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("published journal remains after cancellation: %v", err)
	}
}

func TestListUploadsWithoutStagingDirectoryDoesNotCreateIt(t *testing.T) {
	share := filepath.Join(t.TempDir(), "share")
	s, err := Open(share)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	if _, err := os.Lstat(filepath.Join(share, uploadsDir)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("staging directory unexpectedly exists before listing: %v", err)
	}
	items, next, err := s.ListUploads("", 20)
	if err != nil || len(items) != 0 || next != "" {
		t.Fatalf("empty upload inventory: items=%v next=%q err=%v", items, next, err)
	}
	if _, err := os.Lstat(filepath.Join(share, uploadsDir)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("read-only listing created staging directory: %v", err)
	}
}

func TestUploadAdminMutationsReportBusyDuringUploadTransition(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	state, err := s.BeginUpload("busy.bin", 4, 42)
	if err != nil {
		t.Fatal(err)
	}

	s.uploadMu.Lock()
	if _, _, err := s.ListUploads("", 20); !errors.Is(err, ErrUploadBusy) {
		t.Fatalf("list during a transition = %v, want ErrUploadBusy", err)
	}
	if err := s.CancelUpload(state.ID); !errors.Is(err, ErrUploadBusy) {
		t.Fatalf("cancel during a transition = %v, want ErrUploadBusy", err)
	}
	if removed, skipped, more, err := s.CleanupExpiredUploads(time.Now().Unix()); !errors.Is(err, ErrUploadBusy) || len(removed) != 0 || skipped != 0 || more {
		t.Fatalf("cleanup during a transition: removed=%v skipped=%d more=%v err=%v", removed, skipped, more, err)
	}
	s.uploadMu.Unlock()
}

func TestExpiredUploadCleanupStopsAtInventoryLimitWithoutDeleting(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(filepath.Join(dir, "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	state, err := s.BeginUpload("keep.bin", 4, 42)
	if err != nil {
		t.Fatal(err)
	}
	state.Activity = time.Now().Add(-8 * 24 * time.Hour).Unix()
	if _, err := s.persistUpload(state); err != nil {
		t.Fatal(err)
	}
	partsDir := filepath.Join(dir, "share", filepath.FromSlash(uploadsDir))
	for range maxUploadInventoryRecords {
		id := randomName()
		if err := os.WriteFile(filepath.Join(partsDir, id+".part"), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	removed, skipped, more, err := s.CleanupExpiredUploads(time.Now().Add(-7 * 24 * time.Hour).Unix())
	if !errors.Is(err, ErrUploadInventoryLimit) || len(removed) != 0 || skipped != 0 || more {
		t.Fatalf("over-limit cleanup: removed=%v skipped=%d more=%v err=%v", removed, skipped, more, err)
	}
	if _, err := s.root.Lstat(path.Join(uploadsDir, state.ID+".part")); err != nil {
		t.Fatalf("stale upload part was removed before inventory failure: %v", err)
	}
	if _, err := s.root.Lstat(path.Join(uploadsDir, state.ID+".json")); err != nil {
		t.Fatalf("stale upload journal was removed before inventory failure: %v", err)
	}
}

func TestCancelUploadRejectsPreexistingStagingSymlink(t *testing.T) {
	share := filepath.Join(t.TempDir(), "share")
	s, err := Open(share)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	id := randomName()
	innocent := filepath.Join(share, "innocent")
	if err := os.Mkdir(innocent, 0700); err != nil {
		t.Fatal(err)
	}
	for name, content := range map[string]string{id + ".part": "keep-part", id + ".json": "keep-journal"} {
		if err := os.WriteFile(filepath.Join(innocent, name), []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink("innocent", filepath.Join(share, uploadsDir)); err != nil {
		t.Fatal(err)
	}
	if err := s.CancelUpload(id); !errors.Is(err, ErrType) {
		t.Fatalf("cancel through a preexisting staging symlink = %v, want ErrType", err)
	}
	for name, content := range map[string]string{id + ".part": "keep-part", id + ".json": "keep-journal"} {
		data, err := os.ReadFile(filepath.Join(innocent, name))
		if err != nil || string(data) != content {
			t.Fatalf("cancel changed redirected entry %s: %q %v", name, data, err)
		}
	}
}

func TestCancelUploadUsesPinnedDirectoryDuringSymlinkSwap(t *testing.T) {
	share := filepath.Join(t.TempDir(), "share")
	s, err := Open(share)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	state, err := s.BeginUpload("pinned.bin", 4, 42)
	if err != nil {
		t.Fatal(err)
	}
	innocent := filepath.Join(share, "innocent")
	if err := os.Mkdir(innocent, 0700); err != nil {
		t.Fatal(err)
	}
	for name, content := range map[string]string{state.ID + ".part": "keep-part", state.ID + ".json": "keep-journal"} {
		if err := os.WriteFile(filepath.Join(innocent, name), []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	pinnedPath := filepath.Join(share, uploadsDir+"-pinned-test")
	var swapErr error
	s.beforeUploadRemoval = func() {
		if err := os.Rename(filepath.Join(share, uploadsDir), pinnedPath); err != nil {
			swapErr = err
			return
		}
		swapErr = os.Symlink("innocent", filepath.Join(share, uploadsDir))
	}
	if err := s.CancelUpload(state.ID); err != nil {
		t.Fatalf("cancel on the pinned staging directory: %v", err)
	}
	if swapErr != nil {
		t.Fatalf("swap staging path during cancel: %v", swapErr)
	}
	for name, content := range map[string]string{state.ID + ".part": "keep-part", state.ID + ".json": "keep-journal"} {
		data, err := os.ReadFile(filepath.Join(innocent, name))
		if err != nil || string(data) != content {
			t.Fatalf("cancel escaped the pinned staging directory for %s: %q %v", name, data, err)
		}
		if _, err := os.Lstat(filepath.Join(pinnedPath, name)); !errors.Is(err, fs.ErrNotExist) {
			t.Fatalf("pinned staging entry %s was not removed: %v", name, err)
		}
	}
}
