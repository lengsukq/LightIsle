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

func TestPageAndResumableUploads(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for i := 0; i < 321; i++ {
		name := fmt.Sprintf("asset-%03d.jpg", i)
		if _, err := s.Upload(name, strings.NewReader("data")); err != nil {
			t.Fatal(err)
		}
	}
	cursor := ""
	seen := map[string]bool{}
	for {
		rows, next, err := s.Page(".", cursor, 37)
		if err != nil {
			t.Fatal(err)
		}
		for _, row := range rows {
			if seen[row.Name] {
				t.Fatalf("duplicate item %s", row.Name)
			}
			seen[row.Name] = true
		}
		if next == "" {
			break
		}
		cursor = next
	}
	if len(seen) != 321 {
		t.Fatalf("pagination missed entries: %d", len(seen))
	}
	if _, _, err := s.Page(".", "../secrets", 50); !errors.Is(err, ErrPath) {
		t.Fatal("unsafe cursor")
	}
	if _, _, err := s.Page(".", "", 500); !errors.Is(err, ErrPath) {
		t.Fatal("oversized page")
	}
	state, err := s.BeginUpload("large.bin", 11, 17)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.AppendUpload(state.ID, 18, 0, strings.NewReader("abc")); !errors.Is(err, ErrOwner) {
		t.Fatalf("wrong owner accepted: %v", err)
	}
	if _, err := s.AppendUpload(state.ID, 17, 0, strings.NewReader("hello")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AppendUpload(state.ID, 17, 0, strings.NewReader("again")); !errors.Is(err, ErrOffset) {
		t.Fatalf("out of order: %v", err)
	}
	s.Close()
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	resumed, err := s.UploadInfo(state.ID, 17)
	if err != nil || resumed.Offset != 5 {
		t.Fatalf("resume: %+v %v", resumed, err)
	}
	if _, err := s.AppendUpload(state.ID, 17, 5, strings.NewReader(" world")); err != nil {
		t.Fatal(err)
	}
	if err := s.FinishUpload(state.ID, 17); err != nil {
		t.Fatal(err)
	}
	f, _, err := s.Read("large.bin")
	if err != nil {
		t.Fatal(err)
	}
	data, err := io.ReadAll(f)
	f.Close()
	if err != nil || string(data) != "hello world" {
		t.Fatalf("final data %q %v", data, err)
	}
	if _, err := s.UploadInfo(state.ID, 17); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("session not cleaned")
	}
	state, err = s.BeginUpload("large.bin", 1, 17)
	if !errors.Is(err, ErrExists) {
		t.Fatalf("allowed overwrite upload: %+v %v", state, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "large.bin")); err != nil {
		t.Fatal(err)
	}
}
