package files

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path"
	"path/filepath"
	"testing"
)

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
