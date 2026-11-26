// Package ytdlpbin locates the optional, user-installed yt-dlp binary in the
// same Homebrew whitelist used by aria2c, ffmpeg, smartctl and cloudflared.
// The binary is never searched on PATH, never bundled and never downloaded;
// when it is missing the video archiver degrades honestly with the stable
// reason code ytdlp_not_installed instead of pretending yt-dlp is available.
package ytdlpbin

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/toolprobe"
)

// Reason codes are stable machine strings; the web and native clients map
// them to localized explanations.
const (
	ReasonNotInstalled = "ytdlp_not_installed"
)

var ErrNotInstalled = errors.New(ReasonNotInstalled)

// Only known Homebrew prefixes are probed. Like the other external binaries,
// yt-dlp is never searched on PATH or downloaded.
var Candidates = []string{"/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"}

const (
	versionTimeout   = 8 * time.Second
	maxVersionLength = 64
)

type probe struct {
	mu      sync.Mutex
	checked bool
	path    string
	version string
}

var cached probe

// Locate returns the first usable yt-dlp path and its short version string.
// A successful probe is cached while the binary remains executable on disk; a
// miss is never cached so a later `brew install yt-dlp` is picked up without a
// Core restart.
func Locate() (string, string, error) {
	cached.mu.Lock()
	defer cached.mu.Unlock()
	if cached.checked {
		if cached.path != "" && executable(cached.path) {
			return cached.path, cached.version, nil
		}
		cached.checked = false
		cached.path = ""
		cached.version = ""
	}
	for _, candidate := range Candidates {
		version, err := probeVersion(candidate)
		if err != nil {
			continue
		}
		cached.checked = true
		cached.path = candidate
		cached.version = version
		return candidate, version, nil
	}
	return "", "", ErrNotInstalled
}

func executable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && info.Mode()&0o111 != 0
}

func probeVersion(path string) (string, error) {
	if !executable(path) {
		return "", ErrNotInstalled
	}
	ctx, cancel := context.WithTimeout(context.Background(), versionTimeout)
	defer cancel()
	stdout, err := toolprobe.Run(ctx, path, "--version")
	if err != nil {
		return "", err
	}
	first := strings.TrimSpace(string(stdout))
	if line := strings.IndexByte(first, '\n'); line >= 0 {
		first = strings.TrimSpace(first[:line])
	}
	if !versionLike(first) {
		return "", errors.New("unexpected yt-dlp version output")
	}
	return first, nil
}

// versionLike validates yt-dlp's single-token release version (e.g.
// "2025.03.26", "2025.03.26.232856", "2025.03.26.post1", "2025.03.26-nightly")
// and rejects arbitrary free-form imposter banners.
func versionLike(token string) bool {
	if len(token) < 3 || len(token) > maxVersionLength {
		return false
	}
	if strings.ContainsAny(token, " \t\r\n") {
		return false
	}
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return false
	}
	// First two dot-separated segments must be purely numeric (e.g. YYYY.MM).
	if !allDigits(parts[0]) || !allDigits(parts[1]) {
		return false
	}
	for _, seg := range parts[2:] {
		if !validSuffixSegment(seg) {
			return false
		}
	}
	return true
}

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func validSuffixSegment(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		isDigit := c >= '0' && c <= '9'
		isLetter := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
		if !isDigit && !isLetter && c != '-' && c != '_' {
			return false
		}
	}
	return true
}

// Reset drops the cached probe so tests can substitute candidates. The mutex
// itself must survive: replacing the whole struct would unlock a different,
// never-locked lock.
func Reset() {
	cached.mu.Lock()
	defer cached.mu.Unlock()
	cached.checked = false
	cached.path = ""
	cached.version = ""
}
