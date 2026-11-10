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

func TestVersionProbeRejectsOversizedOutput(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "aria2c")
	if err := os.WriteFile(binary, []byte("#!/bin/sh\necho 'aria2 version 1.0'\n/usr/bin/head -c 65536 /dev/zero\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := probeVersion(binary); err == nil {
		t.Fatal("oversized version output was accepted")
	}
}

func TestLocateDiscoversBinaryInstalledAfterInitialMiss(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "aria2c")
	withCandidatePaths(t, []string{target})
	if _, _, err := Locate(); !errors.Is(err, ErrNotInstalled) {
		t.Fatalf("initial locate should fail with ErrNotInstalled, got %v", err)
	}
	script := "#!/bin/sh\necho 'aria2 version 1.37.0'\n"
	if err := os.WriteFile(target, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	path, version, err := Locate()
	if err != nil || path != target || version != "1.37.0" {
		t.Fatalf("hot locate after install = %q %q %v", path, version, err)
	}
}
