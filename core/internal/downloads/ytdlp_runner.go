package downloads

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	EngineAria2      = "aria2"
	EngineYtDlp      = "ytdlp"
	EngineWebArchive = "webarchive"

	maxYtDlpPlaylistItems = 20
	ytdlpTimeout          = 30 * time.Minute
	maxYtDlpStderrBytes   = 4 << 10
)

// ErrYtDlpNotAvailable reports that yt-dlp is not installed on the host.
// It wraps ErrNotAvailable so legacy callers still map it to 503.
var ErrYtDlpNotAvailable = fmt.Errorf("%w: ytdlp_not_installed", ErrNotAvailable)

// EngineOptions carries optional per-task engine settings persisted as
// options_json in downloads.sqlite.
type EngineOptions struct {
	AllowPlaylist    bool   `json:"allowPlaylist,omitempty"`
	PlaylistMaxItems int    `json:"playlistMaxItems,omitempty"`
	Format           string `json:"format,omitempty"`
}

func (o EngineOptions) isZero() bool {
	return !o.AllowPlaylist && o.PlaylistMaxItems == 0 && o.Format == ""
}

// Status reports availability for all download and archive engines.
type Status struct {
	Available           bool   `json:"available"`
	Version             string `json:"version,omitempty"`
	Reason              string `json:"reason,omitempty"`
	Aria2Available      bool   `json:"aria2Available"`
	Aria2Version        string `json:"aria2Version,omitempty"`
	Aria2Reason         string `json:"aria2Reason,omitempty"`
	YtDlpAvailable      bool   `json:"ytdlpAvailable"`
	YtDlpVersion        string `json:"ytdlpVersion,omitempty"`
	YtDlpReason         string `json:"ytdlpReason,omitempty"`
	WebArchiveAvailable bool   `json:"webArchiveAvailable"`
}

type activeTaskCancel struct {
	token  uint64
	cancel context.CancelFunc
}

// Status returns a live snapshot of aria2, yt-dlp and webarchive readiness.
// Missing optional tools are never cached as missing so a fresh Homebrew
// installation takes effect without a Core restart.
func (m *Manager) Status() Status {
	aria2Avail, aria2Reason := m.Available()
	aria2Ver := m.Version()

	if m.ctx.Err() != nil {
		return Status{
			Available:           false,
			Reason:              "aria2_not_running",
			Aria2Available:      false,
			Aria2Reason:         "aria2_not_running",
			YtDlpAvailable:      false,
			YtDlpReason:         "ytdlp_not_running",
			WebArchiveAvailable: false,
		}
	}

	ytPath, ytVer := m.resolveYtDlp()
	ytAvail := ytPath != ""
	ytReason := ""
	if !ytAvail {
		ytReason = "ytdlp_not_installed"
	}

	return Status{
		Available:           aria2Avail,
		Version:             aria2Ver,
		Reason:              aria2Reason,
		Aria2Available:      aria2Avail,
		Aria2Version:        aria2Ver,
		Aria2Reason:         aria2Reason,
		YtDlpAvailable:      ytAvail,
		YtDlpVersion:        ytVer,
		YtDlpReason:         ytReason,
		WebArchiveAvailable: true,
	}
}

func (m *Manager) resolveYtDlp() (string, string) {
	m.mu.Lock()
	explicit := m.opts.YtDlpBinary
	cachedVer := m.ytdlpVersion
	locate := m.opts.LocateYtDlp
	m.mu.Unlock()

	if explicit != "" {
		if info, err := os.Stat(explicit); err == nil && info.Mode().IsRegular() && info.Mode()&0o111 != 0 {
			return explicit, cachedVer
		}
		return "", ""
	}
	if locate == nil {
		return "", ""
	}
	binPath, version, err := locate()
	if err != nil || binPath == "" {
		return "", ""
	}
	m.mu.Lock()
	if version != "" {
		m.ytdlpVersion = version
	}
	m.mu.Unlock()
	return binPath, version
}

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

func (m *Manager) registerTaskCancel(id string, cancel context.CancelFunc) uint64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.nextCancelToken++
	token := m.nextCancelToken
	if m.activeCancels == nil {
		m.activeCancels = make(map[string]activeTaskCancel)
	}
	m.activeCancels[id] = activeTaskCancel{token: token, cancel: cancel}
	return token
}

func (m *Manager) clearTaskCancel(id string, token uint64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if current, ok := m.activeCancels[id]; ok && current.token == token {
		delete(m.activeCancels, id)
	}
}

func (m *Manager) cancelTaskRunner(id string) {
	m.mu.Lock()
	entry, ok := m.activeCancels[id]
	if ok {
		delete(m.activeCancels, id)
	}
	m.mu.Unlock()
	if ok && entry.cancel != nil {
		entry.cancel()
	}
}

func (m *Manager) ensureEngineReadyLocked(engine string) error {
	switch engine {
	case EngineAria2:
		return m.startLocked()
	case EngineYtDlp:
		if m.ctx.Err() != nil {
			return ErrNotAvailable
		}
		binPath, _ := m.resolveYtDlp()
		if binPath == "" {
			return ErrYtDlpNotAvailable
		}
		return nil
	case EngineWebArchive:
		if m.ctx.Err() != nil {
			return ErrNotAvailable
		}
		return nil
	default:
		return ErrInput
	}
}

func (m *Manager) dispatchTask(id, engine string) {
	switch engine {
	case EngineYtDlp:
		m.kickYtDlp(id)
	case EngineWebArchive:
		m.kickWebArchive(id)
	default:
		m.kick(id)
	}
}

func (m *Manager) kickYtDlp(id string) {
	m.mu.Lock()
	if m.ctx.Err() != nil {
		m.mu.Unlock()
		return
	}
	m.wg.Add(1)
	m.mu.Unlock()
	go func() {
		defer m.wg.Done()
		m.runYtDlpTask(id)
	}()
}

func (m *Manager) runYtDlpTask(id string) {
	m.importMu.Lock()
	task, _, err := m.rowByIDUnscoped(id)
	if err != nil || task.Status != StatusQueued || task.Engine != EngineYtDlp {
		m.importMu.Unlock()
		return
	}
	if !m.canFetch(task.Owner) {
		m.failTask(id, ErrFetchForbidden.Error(), "")
		m.importMu.Unlock()
		return
	}
	if err := m.requireTaskRoot(task); err != nil {
		m.failTask(id, downloadRootError(err), "")
		m.importMu.Unlock()
		return
	}
	binPath, _ := m.resolveYtDlp()
	if binPath == "" {
		m.failTask(id, "ytdlp_not_installed", "")
		m.importMu.Unlock()
		return
	}
	staging := m.stagingDir(id)
	if err := os.MkdirAll(staging, 0o700); err != nil {
		m.failTask(id, "download_staging_failed", "")
		m.importMu.Unlock()
		return
	}
	var opts EngineOptions
	if task.Options != nil {
		opts = *task.Options
	}
	args, err := buildYtDlpArgs(staging, task.URL, task.MaxBytes, opts)
	if err != nil {
		m.failTask(id, ErrInput.Error(), "")
		m.importMu.Unlock()
		return
	}
	if err := m.update(id, "status", StatusRunning, "error", ""); err != nil {
		m.importMu.Unlock()
		return
	}
	runCtx, cancel := context.WithTimeout(m.ctx, ytdlpTimeout)
	token := m.registerTaskCancel(id, cancel)
	m.importMu.Unlock()

	defer func() {
		cancel()
		m.clearTaskCancel(id, token)
	}()

	stderrTail, runErr := m.execYtDlp(runCtx, id, binPath, staging, args)

	m.importMu.Lock()
	defer m.importMu.Unlock()
	current, _, readErr := m.rowByIDUnscoped(id)
	if readErr != nil || current.Status != StatusRunning {
		if readErr == nil && current.Status == StatusCancelled {
			_ = os.RemoveAll(staging)
		}
		return
	}
	if m.ctx.Err() != nil {
		return
	}
	if runErr != nil {
		reason := "ytdlp_failed"
		if errors.Is(runCtx.Err(), context.DeadlineExceeded) {
			reason = "ytdlp_timeout"
		} else if tail := sanitizeText(stderrTail); tail != "" && tail != "download_failed" {
			reason = tail
		}
		m.failTask(id, reason, "")
		return
	}
	removePartialYtDlpFiles(staging)
	m.importDownloadLocked(id)
	if healthy, err := m.noFailedActive(); err == nil && healthy {
		m.lowerAlert()
	}
}

func (m *Manager) execYtDlp(ctx context.Context, taskID, binPath, staging string, args []string) (string, error) {
	cmd := exec.CommandContext(ctx, binPath, args...)
	cmd.Dir = staging
	cmd.WaitDelay = 3 * time.Second
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return "", err
	}
	if err := cmd.Start(); err != nil {
		return "", err
	}

	var stderrBuf boundedTail
	stderrBuf.limit = maxYtDlpStderrBytes
	var streamWG sync.WaitGroup
	streamWG.Add(2)
	go func() {
		defer streamWG.Done()
		m.consumeYtDlpOutput(taskID, stdout, nil)
	}()
	go func() {
		defer streamWG.Done()
		m.consumeYtDlpOutput(taskID, stderr, &stderrBuf)
	}()

	streamWG.Wait()
	waitErr := cmd.Wait()
	return stderrBuf.String(), waitErr
}

var ytdlpProgressRe = regexp.MustCompile(`(\d+(?:\.\d+)?)%\s+of\s+~?\s*(\d+(?:\.\d+)?)\s*([KMGTP]?i?B)`)

func (m *Manager) consumeYtDlpOutput(taskID string, r io.Reader, tail *boundedTail) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 4096), 64*1024)
	lastUpdate := time.Time{}
	for scanner.Scan() {
		line := scanner.Text()
		if tail != nil {
			tail.AppendLine(line)
		}
		total, completed, ok := parseYtDlpProgress(line)
		if !ok {
			continue
		}
		now := time.Now()
		if !lastUpdate.IsZero() && now.Sub(lastUpdate) < 500*time.Millisecond && completed < total {
			continue
		}
		lastUpdate = now
		_ = m.updateRunnerProgress(taskID, total, completed)
	}
}

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

func removePartialYtDlpFiles(staging string) {
	entries, err := os.ReadDir(staging)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if strings.HasSuffix(name, ".part") || strings.HasSuffix(name, ".ytdl") {
			_ = os.Remove(filepath.Join(staging, name))
		}
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
