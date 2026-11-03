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

func TestConcurrentDirectUploadsDoNotSpendTheSameFreeSpace(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	// There is room for exactly one payload above the reserve. Treat a
	// published file and its temporary hard link as the same allocation.
	s.uploadFreeBytes = func(*os.File) (int64, error) {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return 0, err
		}
		var used int64
		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			info, err := entry.Info()
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			if err != nil {
				return 0, err
			}
			used = max(used, info.Size())
		}
		return uploadReserveBytes + 4 - used, nil
	}
	ready := make(chan struct{}, 2)
	start := make(chan struct{})
	results := make(chan error, 2)
	for _, name := range []string{"first.bin", "second.bin"} {
		go func() {
			ready <- struct{}{}
			<-start
			_, err := s.Upload(name, strings.NewReader("data"))
			results <- err
		}()
	}
	<-ready
	<-ready
	close(start)
	success, refused := 0, 0
	for range 2 {
		switch err := <-results; {
		case err == nil:
			success++
		case errors.Is(err, ErrInsufficientSpace):
			refused++
		default:
			t.Fatalf("unexpected upload failure: %v", err)
		}
	}
	if success != 1 || refused != 1 {
		t.Fatalf("want one successful upload and one refusal, got %d and %d", success, refused)
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 2 {
		t.Fatalf("expected only trash and the complete upload: %v %v", entries, err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".lightisle-upload-") {
			t.Fatalf("failed upload left staging behind: %s", entry.Name())
		}
	}
}
