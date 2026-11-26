package ytdlpbin

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
	withCandidatePaths(t, []string{filepath.Join(t.TempDir(), "missing-yt-dlp")})
	_, _, err := Locate()
	if !errors.Is(err, ErrNotInstalled) {
		t.Fatalf("missing binary: %v", err)
	}
}

func TestLocatePrefersFirstUsableCandidate(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "yt-dlp")
	script := "#!/bin/sh\necho '2025.03.26'\n"
	if err := os.WriteFile(good, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	withCandidatePaths(t, []string{filepath.Join(dir, "not-yt-dlp"), good})
	path, version, err := Locate()
	if err != nil || path != good || version != "2025.03.26" {
		t.Fatalf("locate = %q %q %v", path, version, err)
	}
}

func TestLocateAcceptsNightlyAndPostReleaseVersions(t *testing.T) {
	for _, ver := range []string{"2025.03.26.232856", "2025.03.26.post1", "2025.03.26-nightly"} {
		t.Run(ver, func(t *testing.T) {
			dir := t.TempDir()
			bin := filepath.Join(dir, "yt-dlp")
			if err := os.WriteFile(bin, []byte("#!/bin/sh\necho '"+ver+"'\n"), 0o755); err != nil {
				t.Fatal(err)
			}
			withCandidatePaths(t, []string{bin})
			gotPath, gotVer, err := Locate()
			if err != nil || gotPath != bin || gotVer != ver {
				t.Fatalf("locate(%s) = %q %q %v", ver, gotPath, gotVer, err)
			}
		})
	}
}

func TestLocateRejectsImposterOutput(t *testing.T) {
	dir := t.TempDir()
	imposter := filepath.Join(dir, "yt-dlp")
	if err := os.WriteFile(imposter, []byte("#!/bin/sh\necho 'not yt-dlp at all'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	withCandidatePaths(t, []string{imposter})
	_, _, err := Locate()
	if !errors.Is(err, ErrNotInstalled) || !strings.Contains(err.Error(), ReasonNotInstalled) {
		t.Fatalf("imposter accepted: %v", err)
	}
}

func TestLocateRejectsNonExecutableFile(t *testing.T) {
	dir := t.TempDir()
	nonExec := filepath.Join(dir, "yt-dlp")
	if err := os.WriteFile(nonExec, []byte("#!/bin/sh\necho '2025.03.26'\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	withCandidatePaths(t, []string{nonExec})
	if _, _, err := Locate(); !errors.Is(err, ErrNotInstalled) {
		t.Fatalf("non-executable file accepted: %v", err)
	}
}

func TestVersionProbeRejectsOversizedOutput(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "yt-dlp")
	if err := os.WriteFile(binary, []byte("#!/bin/sh\necho '2025.03.26'\n/usr/bin/head -c 65536 /dev/zero\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := probeVersion(binary); err == nil {
		t.Fatal("oversized version output was accepted")
	}
}

func TestLocateHotDiscoversInstallAndRemovalWithoutRestart(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "yt-dlp")
	withCandidatePaths(t, []string{target})
	if _, _, err := Locate(); !errors.Is(err, ErrNotInstalled) {
		t.Fatalf("initial locate should fail with ErrNotInstalled, got %v", err)
	}
	if err := os.WriteFile(target, []byte("#!/bin/sh\necho '2025.03.26'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	path, version, err := Locate()
	if err != nil || path != target || version != "2025.03.26" {
		t.Fatalf("hot locate after install = %q %q %v", path, version, err)
	}
	if err := os.Remove(target); err != nil {
		t.Fatal(err)
	}
	if _, _, err := Locate(); !errors.Is(err, ErrNotInstalled) {
		t.Fatalf("locate after uninstall should fail with ErrNotInstalled, got %v", err)
	}
}
