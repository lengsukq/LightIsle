package files

import (
	"errors"
	"io"
	"os"
	"strings"
	"testing"
)

func TestUploadSpaceGuardRetainsJournalAndNeverPublishesPartialData(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	state, err := s.BeginUpload("photo.bin", 5, 7)
	if err != nil {
		t.Fatal(err)
	}
	const reserve int64 = 64 << 20
	s.uploadFreeBytes = func(_ *os.File) (int64, error) { return reserve + 4, nil }
	if _, err := s.AppendUpload(state.ID, 7, 0, strings.NewReader("hello")); !errors.Is(err, ErrInsufficientSpace) {
		t.Fatalf("expected low-space refusal, got %v", err)
	}
	info, err := s.UploadInfo(state.ID, 7)
	if err != nil || info.Offset != 0 {
		t.Fatalf("journal changed after refusal: %+v %v", info, err)
	}
	if _, _, err := s.Read("photo.bin"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("partial data published: %v", err)
	}
	s.uploadFreeBytes = func(_ *os.File) (int64, error) { return reserve + 5, nil }
	info, err = s.AppendUpload(state.ID, 7, 0, strings.NewReader("hello"))
	if err != nil || info.Offset != 5 {
		t.Fatalf("resume failed: %+v %v", info, err)
	}
	if err := s.FinishUpload(state.ID, 7); err != nil {
		t.Fatal(err)
	}
	f, _, err := s.Read("photo.bin")
	if err != nil {
		t.Fatal(err)
	}
	got, readErr := io.ReadAll(f)
	_ = f.Close()
	if readErr != nil || string(got) != "hello" {
		t.Fatalf("published incorrect data: %q %v", got, readErr)
	}
}

func TestUploadFreeSpaceProbeFailsClosed(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	state, err := s.BeginUpload("photo.bin", 3, 7)
	if err != nil {
		t.Fatal(err)
	}
	s.uploadFreeBytes = func(_ *os.File) (int64, error) { return 0, errors.New("unavailable") }
	if _, err := s.AppendUpload(state.ID, 7, 0, strings.NewReader("abc")); err == nil {
		t.Fatal("availability probe failure must not permit writes")
	}
	info, err := s.UploadInfo(state.ID, 7)
	if err != nil || info.Offset != 0 {
		t.Fatalf("failed probe advanced offset: %+v %v", info, err)
	}
}
