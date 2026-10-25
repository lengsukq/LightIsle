package aria2bin

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func withCandidatePaths(t *testing.T, paths []string) {
	t.Helper()
	original := Candidates
	Candidates = paths
	t.Cleanup(func() {
		Candidates = original
		Reset()
	})
	Reset()
}

func TestLocateMissingBinaryIsHonest(t *testing.T) {
	withCandidatePaths(t, []string{filepath.Join(t.TempDir(), "missing-aria2c")})
	_, _, err := Locate()
	if !errors.Is(err, ErrNotInstalled) {
		t.Fatalf("missing binary: %v", err)
	}
}

func TestLocatePrefersFirstUsableCandidate(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "aria2c")
	script := "#!/bin/sh\necho 'aria2 version 1.37.0'\n"
	if err := os.WriteFile(good, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	withCandidatePaths(t, []string{filepath.Join(dir, "not-aria2c"), good})
	path, version, err := Locate()
	if err != nil || path != good || version != "1.37.0" {
		t.Fatalf("locate = %q %q %v", path, version, err)
	}
}

func TestLocateRejectsImposterOutput(t *testing.T) {
	dir := t.TempDir()
	imposter := filepath.Join(dir, "aria2c")
	if err := os.WriteFile(imposter, []byte("#!/bin/sh\necho 'not aria2 at all'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	withCandidatePaths(t, []string{imposter})
	_, _, err := Locate()
	if !errors.Is(err, ErrNotInstalled) || !strings.Contains(err.Error(), ReasonNotInstalled) {
		t.Fatalf("imposter accepted: %v", err)
	}
}
