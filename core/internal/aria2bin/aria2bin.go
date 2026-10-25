// Package aria2bin locates the optional, user-installed aria2c binary in the
// same Homebrew whitelist used by ffmpeg, smartctl, cloudflared and Docker.
// The binary is never searched on PATH, never bundled and never downloaded;
// when it is missing the download center degrades honestly with the stable
// reason code aria2_not_installed instead of pretending downloads work.
package aria2bin

import (
	"bytes"
	"context"
	"errors"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// Reason codes are stable machine strings; the web and native clients map
// them to localized explanations.
const (
	ReasonNotInstalled = "aria2_not_installed"
	ReasonFailed       = "aria2_failed"
)

var ErrNotInstalled = errors.New(ReasonNotInstalled)

// Only known Homebrew prefixes are probed. Like the other external binaries,
// aria2c is never searched on PATH or downloaded.
var Candidates = []string{"/opt/homebrew/bin/aria2c", "/usr/local/bin/aria2c"}

const versionTimeout = 8 * time.Second

type probe struct {
	mu      sync.Mutex
	checked bool
	path    string
	version string
}

var cached probe

// Locate returns the first usable aria2c path and its short version string.
// The probe runs once per process; missing binaries stay ErrNotInstalled.
func Locate() (string, string, error) {
	cached.mu.Lock()
	defer cached.mu.Unlock()
	if cached.checked {
		return cached.path, cached.version, errFromCache()
	}
	cached.checked = true
	for _, candidate := range Candidates {
		version, err := probeVersion(candidate)
		if err != nil {
			continue
		}
		cached.path = candidate
		cached.version = version
		return candidate, version, nil
	}
	return "", "", ErrNotInstalled
}

func errFromCache() error {
	if cached.path == "" {
		return ErrNotInstalled
	}
	return nil
}

func probeVersion(path string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), versionTimeout)
	defer cancel()
	var stdout bytes.Buffer
	cmd := exec.CommandContext(ctx, path, "--version")
	cmd.Stdout = &stdout
	if err := cmd.Run(); err != nil {
		return "", err
	}
	first := strings.TrimSpace(stdout.String())
	if line := strings.IndexByte(first, '\n'); line >= 0 {
		first = first[:line]
	}
	fields := strings.Fields(first)
	if len(fields) < 2 || fields[0] != "aria2" {
		return "", errors.New("unexpected aria2c version output")
	}
	// Real output is "aria2 version 1.37.0"; accept any numeric token so
	// localized variants still parse, but never trust free-form text.
	for _, field := range fields[1:] {
		if versionLike(field) {
			return field, nil
		}
	}
	return "", errors.New("aria2c version token not found")
}

func versionLike(token string) bool {
	if token == "" {
		return false
	}
	digits := false
	for i, r := range token {
		switch {
		case r >= '0' && r <= '9':
			digits = true
		case r == '.':
			if i == 0 || i == len(token)-1 {
				return false
			}
		default:
			return false
		}
	}
	return digits
}

// Reset drops the cached probe so tests can substitute candidates. The
// mutex itself must survive: replacing the whole struct would unlock a
// different, never-locked lock.
func Reset() {
	cached.mu.Lock()
	defer cached.mu.Unlock()
	cached.checked = false
	cached.path = ""
	cached.version = ""
}
