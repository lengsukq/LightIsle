package files

import (
	"bytes"
	"errors"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"testing"
)

// beginPublishedUpload stages data, links the destination and records the
// published marker, leaving the part and journal for cleanup to remove.
func beginPublishedUpload(t *testing.T, s *Store, destination string, owner int64, data string) UploadState {
	t.Helper()
	state, err := s.BeginUpload(destination, int64(len(data)), owner)
	if err != nil {
		t.Fatal(err)
	}
	state, err = s.AppendUpload(state.ID, owner, 0, bytes.NewReader([]byte(data)))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.linkFile(path.Join(uploadsDir, state.ID+".part"), destination); err != nil {
		t.Fatal(err)
	}
	state.Offset = state.Size
	state.Published = true
	if _, err := s.persistUpload(state); err != nil {
		t.Fatal(err)
	}
	return state
}

func TestUnpublishedUploadMissingPartReturnsNotExist(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	state, err := s.BeginUpload("lost.txt", 4, 42)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.removeFile(path.Join(uploadsDir, state.ID+".part")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UploadInfo(state.ID, 42); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("unpublished journal without part = %v, want ENOENT", err)
	}
}

func TestFinishUploadRetriesWhenPublishedMarkerWriteFails(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	state, err := s.BeginUpload("marker.txt", 4, 42)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.AppendUpload(state.ID, 42, 0, bytes.NewReader([]byte("data"))); err != nil {
		t.Fatal(err)
	}
	fileSyncs := 0
	s.syncFile = func(f *os.File) error {
		fileSyncs++
		if fileSyncs == 2 {
			// The destination link already exists; only the journal temp
			// write backing the published marker fails.
			return errors.New("journal marker write failed")
		}
		return f.Sync()
	}
	if err := s.FinishUpload(state.ID, 42); err == nil {
		t.Fatal("finish acknowledged a failed published marker write")
	}
	if fileSyncs < 2 {
		t.Fatalf("finish skipped the journal write: %d file syncs", fileSyncs)
	}
	if data, err := s.root.ReadFile("marker.txt"); err != nil || !bytes.Equal(data, []byte("data")) {
		t.Fatalf("linked destination lost after marker failure: %q %v", data, err)
	}
	journal, err := s.readUploadJournal(state.ID)
	if err != nil {
		t.Fatalf("journal removed after marker failure: %v", err)
	}
	if journal.Published {
		t.Fatal("published marker survived despite the injected failure")
	}
	if _, err := s.root.Lstat(path.Join(uploadsDir, state.ID+".part")); err != nil {
		t.Fatalf("staged part removed after marker failure: %v", err)
	}
	s.syncFile = nil
	if err := s.FinishUpload(state.ID, 42); err != nil {
		t.Fatalf("retry after marker failure: %v", err)
	}
	for _, ext := range []string{".part", ".json"} {
		if _, err := s.root.Lstat(path.Join(uploadsDir, state.ID+ext)); !errors.Is(err, fs.ErrNotExist) {
			t.Fatalf("residue %s after retried finish: %v", ext, err)
		}
	}
	if data, err := s.root.ReadFile("marker.txt"); err != nil || !bytes.Equal(data, []byte("data")) {
		t.Fatalf("destination data = %q, err=%v", data, err)
	}
}

func TestPublishedUploadFinishesWhenPartAlreadyGone(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	state := beginPublishedUpload(t, s, "published.txt", 42, "data")
	if err := s.removeFile(path.Join(uploadsDir, state.ID+".part")); err != nil {
		t.Fatal(err)
	}
	if err := s.FinishUpload(state.ID, 42); err != nil {
		t.Fatalf("finish with published part already gone: %v", err)
	}
	if data, err := s.root.ReadFile("published.txt"); err != nil || !bytes.Equal(data, []byte("data")) {
		t.Fatalf("destination data = %q, err=%v", data, err)
	}
	if _, err := s.root.Lstat(path.Join(uploadsDir, state.ID+".json")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("journal remained after published cleanup: %v", err)
	}
}

func TestPublishedForeignDestinationIsAbortableWithoutMutation(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	state := beginPublishedUpload(t, s, "taken.txt", 42, "data")
	// Replace the destination with an unrelated file while the staged part
	// still holds the upload's bytes.
	if err := s.removeFile("taken.txt"); err != nil {
		t.Fatal(err)
	}
	foreign, err := s.root.OpenFile("taken.txt", os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := foreign.Write([]byte("foreign")); err != nil {
		t.Fatal(err)
	}
	if err := foreign.Close(); err != nil {
		t.Fatal(err)
	}
	if err := s.FinishUpload(state.ID, 42); !errors.Is(err, ErrExists) {
		t.Fatalf("finish over foreign destination = %v, want ErrExists", err)
	}
	if data, err := s.root.ReadFile("taken.txt"); err != nil || !bytes.Equal(data, []byte("foreign")) {
		t.Fatalf("foreign destination was mutated: %q %v", data, err)
	}
	if _, err := s.root.Lstat(path.Join(uploadsDir, state.ID+".part")); err != nil {
		t.Fatalf("staged part removed while destination was foreign: %v", err)
	}
	if _, err := s.UploadInfo(state.ID, 42); err != nil {
		t.Fatalf("published journal became unreachable: %v", err)
	}
	if err := s.AbortUpload(state.ID, 42); err != nil {
		t.Fatalf("owner abort of foreign published upload: %v", err)
	}
	for _, ext := range []string{".part", ".json"} {
		if _, err := s.root.Lstat(path.Join(uploadsDir, state.ID+ext)); !errors.Is(err, fs.ErrNotExist) {
			t.Fatalf("abort left residue %s: %v", ext, err)
		}
	}
	if data, err := s.root.ReadFile("taken.txt"); err != nil || !bytes.Equal(data, []byte("foreign")) {
		t.Fatalf("abort touched foreign destination: %q %v", data, err)
	}
}

func TestPublishedUploadWithDestinationAndPartGoneIsAbortable(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	state := beginPublishedUpload(t, s, "vanished.txt", 42, "data")
	for _, name := range []string{"vanished.txt", path.Join(uploadsDir, state.ID+".part")} {
		if err := s.removeFile(name); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.UploadInfo(state.ID, 42); err != nil {
		t.Fatalf("corrupt published journal became unreachable: %v", err)
	}
	if err := s.FinishUpload(state.ID, 42); !errors.Is(err, ErrUploadCorrupt) {
		t.Fatalf("finish with destination and part gone = %v, want ErrUploadCorrupt", err)
	}
	if err := s.AbortUpload(state.ID, 42); err != nil {
		t.Fatalf("owner abort of corrupt published upload: %v", err)
	}
	if _, err := s.UploadInfo(state.ID, 42); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("journal remained after abort: %v", err)
	}
}

func TestPublishedUploadPreservesPartWhenDestinationDisappears(t *testing.T) {
	root := filepath.Join(t.TempDir(), "shared")
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	state, err := s.BeginUpload("vanishing.txt", 4, 42)
	if err != nil {
		t.Fatal(err)
	}
	state, err = s.AppendUpload(state.ID, 42, 0, bytes.NewReader([]byte("data")))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.linkFile(path.Join(uploadsDir, state.ID+".part"), "vanishing.txt"); err != nil {
		t.Fatal(err)
	}
	state.Offset = state.Size
	state.Published = true
	if _, err := s.persistUpload(state); err != nil {
		t.Fatal(err)
	}
	if err := s.removeFile("vanishing.txt"); err != nil {
		t.Fatal(err)
	}
	if actual, err := s.UploadInfo(state.ID, 42); err != nil {
		t.Fatalf("published upload info: %+v %v", actual, err)
	} else if actual.Offset != actual.Size {
		t.Fatalf("published upload size mismatch: %+v", actual)
	}
	if err := s.FinishUpload(state.ID, 42); err != nil {
		t.Fatalf("completion did not recover the missing destination: %v", err)
	}
	if _, err := s.root.Lstat(path.Join(uploadsDir, state.ID+".part")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("part was not cleaned after successful republish: %v", err)
	}
	if _, err := s.root.Lstat(path.Join(uploadsDir, state.ID+".json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("journal was not cleaned after successful republish: %v", err)
	}
	data, err := s.root.ReadFile("vanishing.txt")
	if err != nil || !bytes.Equal(data, []byte("data")) {
		t.Fatalf("republished data = %q, err=%v", data, err)
	}
}

func TestResumableUploadCommittedOffsetCrashRecovery(t *testing.T) {
	root := filepath.Join(t.TempDir(), "shared")
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	state, err := s.BeginUpload("archive.bin", 10, 42)
	if err != nil {
		t.Fatal(err)
	}
	if state.Version != 2 || state.Offset != 0 {
		t.Fatalf("new journal not versioned: %+v", state)
	}
	state, err = s.AppendUpload(state.ID, 42, 0, bytes.NewReader([]byte("first")))
	if err != nil || state.Offset != 5 {
		t.Fatalf("commit first chunk: %+v %v", state, err)
	}
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}

	// Simulate a hard crash after bytes reached the part file but before a
	// metadata rename published the new, committed offset.
	part := filepath.Join(root, uploadsDir, state.ID+".part")
	fd, err := os.OpenFile(part, os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = fd.Write([]byte("UNCOMMITTED")); err != nil {
		t.Fatal(err)
	}
	if err = fd.Sync(); err != nil {
		t.Fatal(err)
	}
	fd.Close()

	restarted, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	recovered, err := restarted.UploadInfo(state.ID, 42)
	if err != nil || recovered.Offset != 5 {
		t.Fatalf("cannot roll back uncommitted bytes: %+v %v", recovered, err)
	}
	st, err := os.Stat(part)
	if err != nil || st.Size() != 5 {
		t.Fatalf("part rollback was not durable: %v %v", st, err)
	}
	if _, err = restarted.UploadInfo(state.ID, 43); !errors.Is(err, ErrOwner) {
		t.Fatalf("other account read upload: %v", err)
	}
	if _, err = restarted.AppendUpload(state.ID, 42, 0, bytes.NewReader([]byte("WRONG"))); !errors.Is(err, ErrOffset) {
		t.Fatalf("stale offset accepted: %v", err)
	}
	recovered, err = restarted.AppendUpload(state.ID, 42, 5, bytes.NewReader([]byte("final")))
	if err != nil || recovered.Offset != 10 {
		t.Fatalf("resume from journal: %+v %v", recovered, err)
	}
	if err = restarted.FinishUpload(state.ID, 42); err != nil {
		t.Fatal(err)
	}
	f, _, err := restarted.Read("archive.bin")
	if err != nil {
		t.Fatal(err)
	}
	raw, err := io.ReadAll(f)
	f.Close()
	if err != nil || !bytes.Equal(raw, []byte("firstfinal")) {
		t.Fatalf("data corruption: %q %v", raw, err)
	}
	if _, err := restarted.UploadInfo(state.ID, 42); !os.IsNotExist(err) {
		t.Fatalf("completed upload still active: %v", err)
	}
	if _, err := restarted.BeginUpload("archive.bin", 10, 42); !errors.Is(err, ErrExists) {
		t.Fatalf("unexpected overwrite: %v", err)
	}
}

func TestBeginUploadCleansJournalAfterSyncFailure(t *testing.T) {
	store, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	store.syncDir = func(*os.File) error { return nil }
	if err := store.ensureUploads(); err != nil {
		t.Fatal(err)
	}
	syncCalls := 0
	store.syncDir = func(f *os.File) error {
		syncCalls++
		if syncCalls == 2 || syncCalls == 3 {
			return f.Sync()
		}
		return errors.New("journal directory sync failed")
	}
	if _, err := store.BeginUpload("failed-begin.txt", 1, 42); err == nil {
		t.Fatal("begin succeeded with journal sync failure")
	}
	entries, err := store.root.Open(uploadsDir)
	if err != nil {
		t.Fatal(err)
	}
	defer entries.Close()
	items, err := entries.ReadDir(-1)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 0 {
		t.Fatalf("begin rollback left unreachable upload state: %+v", items)
	}
}

func TestUploadAbortCanRetryAfterPartWasAlreadyRemoved(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	state, err := s.BeginUpload("retry-abort.txt", 1, 42)
	if err != nil {
		t.Fatal(err)
	}
	partPath := path.Join(uploadsDir, state.ID+".part")
	if err := s.removeFile(partPath); err != nil {
		t.Fatal(err)
	}
	if err := s.syncUploadsDirectory(); err != nil {
		t.Fatal(err)
	}
	if err := s.AbortUpload(state.ID, 42); err != nil {
		t.Fatalf("retry abort after part cleanup: %v", err)
	}
	if _, err := s.root.Lstat(path.Join(uploadsDir, state.ID+".json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("journal remains after retry abort: %v", err)
	}
}

func TestUploadAbortRemovesOnlyOwnPart(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	state, err := s.BeginUpload("a.txt", 3, 42)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.AbortUpload(state.ID, 43); !errors.Is(err, ErrOwner) {
		t.Fatalf("other account deleted part: %v", err)
	}
	if err := s.AbortUpload(state.ID, 42); err != nil {
		t.Fatal(err)
	}
	for _, ext := range []string{".part", ".json"} {
		if _, err := s.root.Lstat(path.Join(uploadsDir, state.ID+ext)); !os.IsNotExist(err) {
			t.Fatalf("aborted residue %s: %v", ext, err)
		}
	}
}
