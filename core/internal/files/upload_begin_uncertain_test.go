package files

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestBeginUploadReportsUncertainRollback(t *testing.T) {
	for _, failRollback := range []bool{false, true} {
		t.Run(map[bool]string{false: "rollback_confirmed", true: "rollback_uncertain"}[failRollback], func(t *testing.T) {
			s, err := Open(filepath.Join(t.TempDir(), "share"))
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			if err := s.ensureUploads(); err != nil {
				t.Fatal(err)
			}
			s.syncFile = func(*os.File) error { return errors.New("injected file sync failure") }
			if failRollback {
				s.syncDir = func(*os.File) error { return errors.New("injected rollback sync failure") }
			}
			_, err = s.BeginUpload("photo.jpg", 3, 42)
			if err == nil || errors.Is(err, ErrUploadBeginUncertain) != failRollback {
				t.Fatalf("begin error does not reflect rollback: %v", err)
			}
		})
	}
}
