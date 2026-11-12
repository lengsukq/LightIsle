package cinema

import (
	"errors"
	"io"
	"net"
	"net/netip"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
)

const maxStrmFileBytes = 4096

var (
	ErrInvalidStrmURL   = errors.New("invalid_strm_url")
	ErrForbiddenStrmURL = errors.New("forbidden_strm_url")
)

// IsStrmPath reports whether p is a .strm virtual stream descriptor file.
func IsStrmPath(p string) bool {
	return strings.EqualFold(filepath.Ext(p), ".strm")
}

// ReadAndValidateStrmURL reads a single HTTP/HTTPS stream URL from an open
// .strm file and enforces scheme, syntax, and loopback/link-local SSRF guards.
func ReadAndValidateStrmURL(f *os.File) (string, error) {
	if f == nil {
		return "", ErrInvalidStrmURL
	}
	raw, err := io.ReadAll(io.LimitReader(f, maxStrmFileBytes+1))
	if err != nil || len(raw) == 0 || len(raw) > maxStrmFileBytes {
		return "", ErrInvalidStrmURL
	}
	return ParseAndValidateStrmContent(string(raw))
}

// ParseAndValidateStrmContent extracts and validates the target stream URL from
// raw .strm file text. Comments (#) and blank lines are skipped; multiple URLs
// or non-HTTP(S) schemes are rejected.
func ParseAndValidateStrmContent(content string) (string, error) {
	content = strings.TrimPrefix(content, "\xef\xbb\xbf")
	if strings.ContainsRune(content, 0) {
		return "", ErrInvalidStrmURL
	}
	var target string
	for _, line := range strings.Split(content, "\n") {
		trimmed := strings.TrimSpace(strings.TrimSuffix(line, "\r"))
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if target != "" {
			// A .strm descriptor must point to one canonical stream target.
			return "", ErrInvalidStrmURL
		}
		target = trimmed
	}
	if target == "" || len(target) > 2048 || strings.ContainsAny(target, " \t\r\n") {
		return "", ErrInvalidStrmURL
	}
	parsed, err := url.Parse(target)
	if err != nil || parsed.Host == "" {
		return "", ErrInvalidStrmURL
	}
	scheme := strings.ToLower(parsed.Scheme)
	if scheme != "http" && scheme != "https" {
		return "", ErrForbiddenStrmURL
	}
	host := strings.ToLower(strings.TrimSpace(parsed.Hostname()))
	if host == "" {
		return "", ErrInvalidStrmURL
	}
	if isBlockedStrmHost(host) {
		return "", ErrForbiddenStrmURL
	}
	return parsed.String(), nil
}

func isBlockedStrmHost(host string) bool {
	if host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return true
	}
	if addr, err := netip.ParseAddr(host); err == nil {
		addr = addr.Unmap()
		if addr.IsLoopback() || addr.IsUnspecified() || addr.IsMulticast() || addr.IsLinkLocalUnicast() || addr.IsLinkLocalMulticast() {
			return true
		}
		return false
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback() || ip.IsUnspecified() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast()
	}
	return false
}

// StrmHostSummary extracts the display hostname for UI badges without exposing
// signed query tokens or credentials embedded in the .strm URL.
func StrmHostSummary(rawURL string) string {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}
	return strings.ToLower(parsed.Hostname())
}

// InferStrmMime infers a browser-friendly media MIME type from the URL path.
func InferStrmMime(rawURL string) string {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return "video/mp4"
	}
	switch strings.ToLower(path.Ext(parsed.Path)) {
	case ".m3u8":
		return "application/vnd.apple.mpegurl"
	case ".webm":
		return "video/webm"
	case ".mkv":
		return "video/x-matroska"
	case ".mov":
		return "video/quicktime"
	case ".ts":
		return "video/mp2t"
	default:
		return "video/mp4"
	}
}
