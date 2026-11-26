package downloads

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"github.com/lengsukq/lightisle/core/internal/webarchive"
)

// NormalizeEngine defaults an empty engine to aria2 and rejects unknown names.
func NormalizeEngine(engine string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(engine)) {
	case "", EngineAria2:
		return EngineAria2, nil
	case EngineYtDlp:
		return EngineYtDlp, nil
	case EngineWebArchive:
		return EngineWebArchive, nil
	default:
		return "", ErrInput
	}
}

// ValidateYtDlpURL enforces strict http/https-only URLs and rejects leading
// dashes, embedded credentials, whitespace or control characters so URLs can
// never act as yt-dlp CLI flags.
func ValidateYtDlpURL(raw string) error {
	if raw == "" || len(raw) > maxURLLength {
		return ErrInput
	}
	if strings.HasPrefix(raw, "-") {
		return ErrInput
	}
	for _, r := range raw {
		if r <= 0x20 || r == 0x7f {
			return ErrInput
		}
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return ErrInput
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http", "https":
	default:
		return ErrInput
	}
	if parsed.Host == "" || parsed.Hostname() == "" || parsed.User != nil {
		return ErrInput
	}
	if _, _, err := net.SplitHostPort(hostnamePort(parsed)); err != nil && parsed.Port() != "" {
		return ErrInput
	}
	return nil
}

// ValidateEngineOptions validates and normalizes per-engine options.
func ValidateEngineOptions(engine string, opts EngineOptions) (EngineOptions, error) {
	if engine != EngineYtDlp {
		return EngineOptions{}, nil
	}
	out := EngineOptions{
		AllowPlaylist:    opts.AllowPlaylist,
		PlaylistMaxItems: opts.PlaylistMaxItems,
		Format:           strings.ToLower(strings.TrimSpace(opts.Format)),
	}
	switch out.Format {
	case "", "best", "1080p", "720p", "audio":
	default:
		return EngineOptions{}, ErrInput
	}
	if out.PlaylistMaxItems < 0 || out.PlaylistMaxItems > maxYtDlpPlaylistItems {
		return EngineOptions{}, ErrInput
	}
	if out.AllowPlaylist {
		if out.PlaylistMaxItems == 0 {
			out.PlaylistMaxItems = maxYtDlpPlaylistItems
		}
	} else {
		out.PlaylistMaxItems = 0
	}
	return out, nil
}

func encodeEngineOptions(opts EngineOptions) (string, error) {
	if opts.isZero() {
		return "{}", nil
	}
	raw, err := json.Marshal(opts)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func decodeEngineOptions(raw string) *EngineOptions {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || trimmed == "{}" {
		return nil
	}
	var opts EngineOptions
	if err := json.Unmarshal([]byte(trimmed), &opts); err != nil || opts.isZero() {
		return nil
	}
	return &opts
}

func buildYtDlpArgs(stagingDir, rawURL string, maxBytes int64, opts EngineOptions) ([]string, error) {
	if err := ValidateYtDlpURL(rawURL); err != nil {
		return nil, err
	}
	normOpts, err := ValidateEngineOptions(EngineYtDlp, opts)
	if err != nil {
		return nil, err
	}
	args := []string{
		"--ignore-config",
		"--no-exec",
		"--no-overwrites",
		"--restrict-filenames",
		"--newline",
		"--progress",
		"--no-color",
		"--paths", stagingDir,
		"--output", "%(title).80s [%(id).20s].%(ext)s",
	}
	if normOpts.AllowPlaylist {
		limit := normOpts.PlaylistMaxItems
		if limit <= 0 || limit > maxYtDlpPlaylistItems {
			limit = maxYtDlpPlaylistItems
		}
		args = append(args, "--yes-playlist", "--playlist-end", strconv.Itoa(limit))
	} else {
		args = append(args, "--no-playlist")
	}
	if maxBytes > 0 {
		args = append(args, "--max-filesize", strconv.FormatInt(maxBytes, 10))
	}
	switch normOpts.Format {
	case "1080p":
		args = append(args, "-f", "bv*[height<=1080]+ba/b[height<=1080]/b")
	case "720p":
		args = append(args, "-f", "bv*[height<=720]+ba/b[height<=720]/b")
	case "audio":
		args = append(args, "-f", "ba/b")
	}
	// Terminate option parsing so rawURL can never be interpreted as a flag.
	args = append(args, "--", rawURL)
	return args, nil
}

func (m *Manager) checkYtDlpHost(ctx context.Context, rawURL string) error {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return ErrInput
	}
	host := strings.SplitN(strings.TrimSpace(parsed.Hostname()), "%", 2)[0]
	var allowHosts []string
	if m.opts.WebArchiveOptions != nil {
		allowHosts = m.opts.WebArchiveOptions.AllowHosts
	}
	if hostInAllowList(allowHosts, host) {
		return nil
	}
	if ip := net.ParseIP(host); ip != nil {
		if webarchive.IsBlockedIP(ip) {
			return fmt.Errorf("%w: %s", webarchive.ErrBlockedAddress, host)
		}
		return nil
	}
	if isBlockedYtDlpHostname(host) || isNonCanonicalNumericHost(host) {
		return fmt.Errorf("%w: %s", webarchive.ErrBlockedAddress, host)
	}
	lookup := m.opts.LookupIPAddr
	if lookup == nil {
		lookup = net.DefaultResolver.LookupIPAddr
	}
	lookupCtx, cancel := context.WithTimeout(ctx, ytdlpDNSLookupTimeout)
	defer cancel()
	ips, err := lookup(lookupCtx, host)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return nil
	}
	for _, addr := range ips {
		if !hostInAllowList(allowHosts, addr.IP.String()) && webarchive.IsBlockedIP(addr.IP) {
			return fmt.Errorf("%w: resolved private address", webarchive.ErrBlockedAddress)
		}
	}
	return nil
}

func hostInAllowList(allowHosts []string, target string) bool {
	for _, allowed := range allowHosts {
		if strings.EqualFold(strings.TrimSpace(allowed), strings.TrimSpace(target)) {
			return true
		}
	}
	return false
}

func isBlockedYtDlpHostname(host string) bool {
	h := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(host), "."))
	return h == "" || h == "localhost" ||
		strings.HasSuffix(h, ".localhost") ||
		strings.HasSuffix(h, ".local") ||
		strings.HasSuffix(h, ".internal")
}

// isNonCanonicalNumericHost rejects octal/hex/integer/shortened IPv4 notations
// (e.g. 127.1, 2130706433, 0x7f000001) that net.ParseIP misses yet OS resolvers
// can map to loopback or private addresses.
func isNonCanonicalNumericHost(host string) bool {
	parts := strings.Split(strings.TrimSuffix(host, "."), ".")
	if len(parts) == 0 || len(parts) > 4 {
		return false
	}
	for _, part := range parts {
		if part == "" {
			return false
		}
		if _, err := strconv.ParseUint(part, 0, 64); err != nil {
			return false
		}
	}
	return true
}

func injectYtDlpFFmpegLocation(args []string, ffmpegPath string) []string {
	if ffmpegPath == "" {
		return args
	}
	out := make([]string, 0, len(args)+2)
	inserted := false
	for _, arg := range args {
		if !inserted && arg == "--" {
			out = append(out, "--ffmpeg-location", ffmpegPath)
			inserted = true
		}
		out = append(out, arg)
	}
	if !inserted {
		out = append(out, "--ffmpeg-location", ffmpegPath)
	}
	return out
}

func withTrustedHomebrewPATH(env []string) []string {
	out := make([]string, 0, len(env)+1)
	found := false
	for _, kv := range env {
		if strings.HasPrefix(kv, "PATH=") {
			found = true
			cur := strings.TrimPrefix(kv, "PATH=")
			out = append(out, "PATH="+appendTrustedPathEntries(cur))
			continue
		}
		out = append(out, kv)
	}
	if !found {
		out = append(out, "PATH="+trustedHomebrewPathEntry)
	}
	return out
}

func appendTrustedPathEntries(current string) string {
	entries := strings.Split(current, string(os.PathListSeparator))
	seen := make(map[string]bool, len(entries)+2)
	clean := make([]string, 0, len(entries)+2)
	for _, e := range entries {
		if e != "" && !seen[e] {
			seen[e] = true
			clean = append(clean, e)
		}
	}
	for _, trusted := range strings.Split(trustedHomebrewPathEntry, ":") {
		if !seen[trusted] {
			seen[trusted] = true
			clean = append(clean, trusted)
		}
	}
	return strings.Join(clean, string(os.PathListSeparator))
}

func stagingTreeBytes(staging string) int64 {
	var total int64
	_ = filepath.WalkDir(staging, func(_ string, d fs.DirEntry, err error) error {
		if err != nil || d == nil || !d.Type().IsRegular() {
			return nil
		}
		if info, infoErr := d.Info(); infoErr == nil {
			total += info.Size()
		}
		return nil
	})
	return total
}

var ytdlpProgressRe = regexp.MustCompile(`(\d+(?:\.\d+)?)%\s+of\s+~?\s*(\d+(?:\.\d+)?)\s*([KMGTP]?i?B)`)

func parseYtDlpProgress(line string) (total, completed int64, ok bool) {
	matches := ytdlpProgressRe.FindStringSubmatch(line)
	if len(matches) != 4 {
		return 0, 0, false
	}
	pct, err1 := strconv.ParseFloat(matches[1], 64)
	size, err2 := strconv.ParseFloat(matches[2], 64)
	if err1 != nil || err2 != nil || pct < 0 || size <= 0 {
		return 0, 0, false
	}
	mult := byteUnitMultiplier(matches[3])
	if mult <= 0 {
		return 0, 0, false
	}
	total = int64(size * mult)
	if pct > 100 {
		pct = 100
	}
	completed = int64(float64(total) * (pct / 100.0))
	return total, completed, true
}

func byteUnitMultiplier(unit string) float64 {
	switch unit {
	case "B":
		return 1
	case "KiB":
		return 1024
	case "KB":
		return 1000
	case "MiB":
		return 1024 * 1024
	case "MB":
		return 1000 * 1000
	case "GiB":
		return 1024 * 1024 * 1024
	case "GB":
		return 1000 * 1000 * 1000
	case "TiB":
		return 1024 * 1024 * 1024 * 1024
	case "TB":
		return 1000 * 1000 * 1000 * 1000
	default:
		return 0
	}
}

type boundedTail struct {
	mu    sync.Mutex
	limit int
	buf   bytes.Buffer
}

func (b *boundedTail) AppendLine(line string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.buf.Len() > 0 {
		b.buf.WriteByte(' ')
	}
	b.buf.WriteString(strings.TrimSpace(line))
	if b.buf.Len() > b.limit {
		excess := b.buf.Len() - b.limit
		b.buf.Next(excess)
	}
}

func (b *boundedTail) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}
