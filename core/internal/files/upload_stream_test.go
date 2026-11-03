package files

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Produces large chunks without retaining a corresponding in-memory fixture.
type uploadPatternReader struct {
	remaining int64
	maxRead   int
}

func (r *uploadPatternReader) Read(p []byte) (int, error) {
	if r.maxRead > 0 && len(p) > r.maxRead {
		return 0, fmt.Errorf("read buffer %d exceeds %d", len(p), r.maxRead)
	}
	if r.remaining == 0 {
		return 0, io.EOF
	}
	n := int(min(int64(len(p)), r.remaining))
	for i := range p[:n] {
		p[i] = 'x'
	}
	r.remaining -= int64(n)
	return n, nil
}

func BenchmarkAppendUpload(b *testing.B) {
	for _, size := range []int64{64 << 10, maxChunk} {
		b.Run(fmt.Sprint(size), func(b *testing.B) {
			s, err := Open(b.TempDir())
			if err != nil {
				b.Fatal(err)
			}
			defer s.Close()
			b.ReportAllocs()
			b.SetBytes(size)
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				b.StopTimer()
				state, err := s.BeginUpload("chunk.bin", size, 7)
				if err != nil {
					b.Fatal(err)
				}
				source := &uploadPatternReader{remaining: size}
				b.StartTimer()
				got, err := s.AppendUpload(state.ID, 7, 0, source)
				b.StopTimer()
				if err != nil || got.Offset != size {
					b.Fatalf("append: %+v %v", got, err)
				}
				if err := s.AbortUpload(state.ID, 7); err != nil {
					b.Fatal(err)
				}
				b.StartTimer()
			}
		})
	}
}

func TestAppendUploadStreamsWithBoundedBuffer(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	state, err := s.BeginUpload("chunk.bin", maxChunk, 7)
	if err != nil {
		t.Fatal(err)
	}
	source := &uploadPatternReader{remaining: maxChunk, maxRead: 64 << 10}
	got, err := s.AppendUpload(state.ID, 7, 0, source)
	if err != nil || got.Offset != maxChunk {
		t.Fatalf("bounded append: %+v %v", got, err)
	}
	if err := s.FinishUpload(state.ID, 7); err != nil {
		t.Fatal(err)
	}
	f, info, err := s.Read("chunk.bin")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if info.Size() != maxChunk {
		t.Fatalf("published size=%d", info.Size())
	}
	buffer := make([]byte, 32<<10)
	for {
		n, err := f.Read(buffer)
		for _, value := range buffer[:n] {
			if value != 'x' {
				t.Fatal("published bytes changed")
			}
		}
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
	}
}

type uploadFailureReader struct{ err error }

func (r uploadFailureReader) Read([]byte) (int, error) { return 0, r.err }

type uploadSwapReader struct {
	swap func() error
}

func (r *uploadSwapReader) Read(p []byte) (int, error) {
	if r.swap == nil {
		return 0, io.EOF
	}
	if err := r.swap(); err != nil {
		return 0, err
	}
	r.swap = nil
	return copy(p, "data"), nil
}

func TestAppendUploadRejectsPartReplacedDuringStream(t *testing.T) {
	root := t.TempDir()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	state, err := s.BeginUpload("destination.bin", 4, 7)
	if err != nil {
		t.Fatal(err)
	}
	part := filepath.Join(root, uploadsDir, state.ID+".part")
	source := &uploadSwapReader{swap: func() error {
		if err := os.Rename(part, part+"-original"); err != nil {
			return err
		}
		return os.WriteFile(part, []byte("foreign data"), 0600)
	}}
	if _, err := s.AppendUpload(state.ID, 7, 0, source); !errors.Is(err, ErrUploadCorrupt) {
		t.Fatalf("replaced part accepted: %v", err)
	}
	if data, err := os.ReadFile(part); err != nil || string(data) != "foreign data" {
		t.Fatalf("replacement modified: %q %v", data, err)
	}
	if data, err := os.ReadFile(part + "-original"); err != nil || len(data) != 0 {
		t.Fatalf("original part not rolled back: %q %v", data, err)
	}
	journal, err := readUploadJournalFrom(s.uploadsRoot, state.ID)
	if err != nil || journal.Offset != 0 {
		t.Fatalf("replaced part advanced journal: %+v %v", journal, err)
	}
}

func TestAppendUploadStreamFailuresRetainCommittedPrefix(t *testing.T) {
	disconnected := errors.New("connection lost")
	for _, name := range []string{"read_failure", "chunk_limit", "remaining_size", "disk_space"} {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			s, err := Open(root)
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			size := maxChunk + 6
			if name == "remaining_size" {
				size = 100_000
			}
			state, err := s.BeginUpload("chunk.bin", size, 7)
			if err != nil {
				t.Fatal(err)
			}
			state, err = s.AppendUpload(state.ID, 7, 0, strings.NewReader("prefix"))
			if err != nil {
				t.Fatal(err)
			}
			var source io.Reader
			wantErr := ErrSize
			switch name {
			case "read_failure":
				source = io.MultiReader(&uploadPatternReader{remaining: 100_000}, uploadFailureReader{disconnected})
				wantErr = disconnected
			case "chunk_limit":
				source = &uploadPatternReader{remaining: maxChunk + 1}
			case "remaining_size":
				source = &uploadPatternReader{remaining: size}
			case "disk_space":
				source = &uploadPatternReader{remaining: 200_000}
				s.uploadFreeBytes = func(*os.File) (int64, error) { return (64 << 20) + 100_000, nil }
				wantErr = ErrInsufficientSpace
			}
			if _, err := s.AppendUpload(state.ID, 7, state.Offset, source); !errors.Is(err, wantErr) {
				t.Fatalf("error=%v, want %v", err, wantErr)
			}
			got, err := s.UploadInfo(state.ID, 7)
			if err != nil || got.Offset != 6 {
				t.Fatalf("failed chunk advanced journal: %+v %v", got, err)
			}
			part := filepath.Join(root, uploadsDir, state.ID+".part")
			data, err := os.ReadFile(part)
			if err != nil || string(data) != "prefix" {
				t.Fatalf("failed chunk changed prefix: %q %v", data, err)
			}
			if _, err := os.Stat(filepath.Join(root, "chunk.bin")); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("failed chunk was published: %v", err)
			}
			s.uploadFreeBytes = nil
			if err := s.Close(); err != nil {
				t.Fatal(err)
			}
			reopened, err := Open(root)
			if err != nil {
				t.Fatal(err)
			}
			defer reopened.Close()
			got, err = reopened.AppendUpload(state.ID, 7, 6, strings.NewReader("retry"))
			if err != nil || got.Offset != 11 {
				t.Fatalf("cannot retry after reopening: %+v %v", got, err)
			}
		})
	}
}

func TestDirectUploadDoesNotPublishIntoReplacementDirectory(t *testing.T) {
	root := t.TempDir()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, name := range []string{"target", "private"} {
		if err := os.Mkdir(filepath.Join(root, name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	var foreignStage string
	source := &uploadSwapReader{swap: func() error {
		entries, err := os.ReadDir(filepath.Join(root, "target"))
		if err != nil {
			return err
		}
		if len(entries) != 1 {
			t.Fatalf("expected one staged upload before swapping directory, got %v", entries)
		}
		foreignStage = filepath.Join(root, "private", entries[0].Name())
		if err := os.WriteFile(foreignStage, []byte("private data"), 0600); err != nil {
			return err
		}
		if err := os.Rename(filepath.Join(root, "target"), filepath.Join(root, "old")); err != nil {
			return err
		}
		return os.Symlink("private", filepath.Join(root, "target"))
	}}
	if _, err := s.Upload("target/payload.bin", source); !errors.Is(err, ErrPath) {
		t.Fatalf("upload accepted replaced directory: %v", err)
	}
	entries, err := os.ReadDir(filepath.Join(root, "old"))
	if err != nil || len(entries) != 0 {
		t.Fatalf("staging remained in the original directory: %v %v", entries, err)
	}
	if _, err := os.Lstat(filepath.Join(root, "private", "payload.bin")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("upload published in private directory: %v", err)
	}
	foreignData, err := os.ReadFile(foreignStage)
	if err != nil || string(foreignData) != "private data" {
		t.Fatalf("upload changed foreign staging entry: %q %v", foreignData, err)
	}
}
