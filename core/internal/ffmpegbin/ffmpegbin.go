// Package ffmpegbin locates the optional, user-installed FFmpeg and ffprobe
// binaries in the same Homebrew whitelist used by smartctl, cloudflared and
// Docker. The binaries are never searched on PATH, never bundled and never
// downloaded; when they are missing every dependent capability degrades
// honestly with the stable reason code ffmpeg_not_installed instead of
// pretending transcode is available.
package ffmpegbin

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// Reason codes are stable machine strings; the web and native clients map
// them to localized explanations.
const (
	ReasonNotInstalled = "ffmpeg_not_installed"
	ReasonFailed       = "ffmpeg_failed"
)

var (
	ErrNotInstalled = errors.New(ReasonNotInstalled)
	ErrFailed       = errors.New(ReasonFailed)
)

// Only known Homebrew prefixes are probed. Like the Docker runtime and the
// media worker, external binaries are never searched on PATH or downloaded.
var (
	ffmpegCandidates  = []string{"/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"}
	ffprobeCandidates = []string{"/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"}
)

const versionTimeout = 8 * time.Second

type result struct {
	stdout   []byte
	stderr   []byte
	exitCode int
	err      error
}

type Tools struct {
	mu       sync.Mutex
	checked  bool
	ffmpeg   string
	ffprobe  string
	version  string
	run      func(ctx context.Context, path string, args ...string) result
	probeVer func(ctx context.Context, path string) (string, error)
}

func New() *Tools {
	t := &Tools{}
	t.run = runBinary
	t.probeVer = t.probeVersion
	return t
}

// NewWithPaths builds Tools around explicit binary paths. It exists for
// embedders and tests; production code uses New() and the Homebrew whitelist.
func NewWithPaths(ffmpeg, ffprobe string) *Tools {
	t := New()
	t.ffmpeg, t.ffprobe, t.checked = ffmpeg, ffprobe, true
	return t
}

func runBinary(ctx context.Context, path string, args ...string) result {
	ctx, cancel := context.WithTimeout(ctx, versionTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, args...)
	stdout := &bytes.Buffer{}
	stderr := &bytes.Buffer{}
	cmd.Stdout, cmd.Stderr = stdout, stderr
	err := cmd.Run()
	exitCode := 0
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		exitCode = exitErr.ExitCode()
	} else if err != nil {
		return result{stdout: stdout.Bytes(), stderr: stderr.Bytes(), err: err}
	}
	return result{stdout: stdout.Bytes(), stderr: stderr.Bytes(), exitCode: exitCode}
}

func executable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && info.Mode()&0111 != 0
}

func (t *Tools) probe() {
	if t.checked {
		return
	}
	for _, path := range ffmpegCandidates {
		if executable(path) {
			t.ffmpeg = path
			break
		}
	}
	for _, path := range ffprobeCandidates {
		if executable(path) {
			t.ffprobe = path
			break
		}
	}
	t.checked = t.ffmpeg != "" && t.ffprobe != ""
}

// FFmpeg returns the whitelisted ffmpeg path. A miss is not cached so a later
// `brew install ffmpeg` is picked up without a Core restart; two stat calls
// per lookup are cheap.
func (t *Tools) FFmpeg() (string, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.probe()
	if t.ffmpeg == "" {
		return "", ErrNotInstalled
	}
	return t.ffmpeg, nil
}

// FFprobe returns the whitelisted ffprobe path with the same caching rules
// as FFmpeg.
func (t *Tools) FFprobe() (string, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.probe()
	if t.ffprobe == "" {
		return "", ErrNotInstalled
	}
	return t.ffprobe, nil
}

func (t *Tools) probeVersion(ctx context.Context, path string) (string, error) {
	out := t.run(ctx, path, "-version")
	if out.err != nil || out.exitCode != 0 {
		return "", ErrFailed
	}
	first := strings.SplitN(string(bytes.TrimSpace(out.stdout)), "\n", 2)[0]
	first = strings.TrimSpace(first)
	if first == "" || len(first) > 200 {
		return "", ErrFailed
	}
	return first, nil
}

// Version reports the cached `ffmpeg -version` banner for the status
// endpoint. A failed probe is retried on the next call, never cached.
func (t *Tools) Version(ctx context.Context) (string, error) {
	t.mu.Lock()
	t.probe()
	if t.ffmpeg == "" {
		t.mu.Unlock()
		return "", ErrNotInstalled
	}
	if t.version != "" {
		cached := t.version
		t.mu.Unlock()
		return cached, nil
	}
	path := t.ffmpeg
	t.mu.Unlock()
	version, err := t.probeVer(ctx, path)
	t.mu.Lock()
	if err != nil {
		t.mu.Unlock()
		return "", err
	}
	t.version = version
	cached := t.version
	t.mu.Unlock()
	return cached, nil
}
