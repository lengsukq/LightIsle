package ffmpegbin

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func withCandidates(t *testing.T, dir string) {
	t.Helper()
	originalFFmpeg, originalFFprobe := ffmpegCandidates, ffprobeCandidates
	ffmpegCandidates = []string{filepath.Join(dir, "ffmpeg")}
	ffprobeCandidates = []string{filepath.Join(dir, "ffprobe")}
	t.Cleanup(func() {
		ffmpegCandidates, ffprobeCandidates = originalFFmpeg, originalFFprobe
	})
}

func TestNotInstalled(t *testing.T) {
	withCandidates(t, t.TempDir())
	tools := New()
	if _, err := tools.FFmpeg(); !errors.Is(err, ErrNotInstalled) {
		t.Fatalf("FFmpeg error = %v, want ErrNotInstalled", err)
	}
	if _, err := tools.FFprobe(); !errors.Is(err, ErrNotInstalled) {
		t.Fatalf("FFprobe error = %v, want ErrNotInstalled", err)
	}
	if _, err := tools.Version(context.Background()); !errors.Is(err, ErrNotInstalled) {
		t.Fatalf("Version error = %v, want ErrNotInstalled", err)
	}
}

func writeScript(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestFoundAfterInstall(t *testing.T) {
	dir := t.TempDir()
	withCandidates(t, dir)
	tools := New()
	// A miss must stay uncached so a later brew install is picked up.
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeScript(t, filepath.Join(dir, "ffmpeg"), "echo 'ffmpeg version 7.1'\n")
	writeScript(t, filepath.Join(dir, "ffprobe"), "echo 'ffprobe version 7.1'\n")
	if path, err := tools.FFmpeg(); err != nil || path != filepath.Join(dir, "ffmpeg") {
		t.Fatalf("FFmpeg = (%q, %v)", path, err)
	}
	version, err := tools.Version(context.Background())
	if err != nil || version != "ffmpeg version 7.1" {
		t.Fatalf("Version = (%q, %v)", version, err)
	}
	// The banner is cached; removing the binary keeps the cached answer valid
	// for the lifetime of the process, matching the diskhealth pattern.
	if err := os.Remove(filepath.Join(dir, "ffmpeg")); err != nil {
		t.Fatal(err)
	}
	if version, err := tools.Version(context.Background()); err != nil || version != "ffmpeg version 7.1" {
		t.Fatalf("cached Version = (%q, %v)", version, err)
	}
}

func TestVersionFailureNotCached(t *testing.T) {
	dir := t.TempDir()
	withCandidates(t, dir)
	writeScript(t, filepath.Join(dir, "ffmpeg"), "exit 1\n")
	tools := New()
	if _, err := tools.Version(context.Background()); !errors.Is(err, ErrFailed) {
		t.Fatalf("Version error = %v, want ErrFailed", err)
	}
	calls := 0
	tools.probeVer = func(context.Context, string) (string, error) {
		calls++
		return "ffmpeg version 7.1", nil
	}
	if _, err := tools.Version(context.Background()); err != nil || calls != 1 {
		t.Fatalf("Version after failure = calls %d err %v, want one retry", calls, err)
	}
}

func TestInjectedProbeVersionUsed(t *testing.T) {
	dir := t.TempDir()
	withCandidates(t, dir)
	writeScript(t, filepath.Join(dir, "ffmpeg"), "echo ignored\n")
	tools := New()
	tools.probeVer = func(context.Context, string) (string, error) {
		return "ffmpeg version N-1", nil
	}
	version, err := tools.Version(context.Background())
	if err != nil || version != "ffmpeg version N-1" {
		t.Fatalf("Version = (%q, %v)", version, err)
	}
}
