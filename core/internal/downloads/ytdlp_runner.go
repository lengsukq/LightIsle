package downloads

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/ffmpegbin"
	"github.com/lengsukq/lightisle/core/internal/webarchive"
)

const (
	EngineAria2      = "aria2"
	EngineYtDlp      = "ytdlp"
	EngineWebArchive = "webarchive"

	maxYtDlpPlaylistItems    = 20
	ytdlpTimeout             = 30 * time.Minute
	maxYtDlpStderrBytes      = 4 << 10
	ytdlpSizePollInterval    = 250 * time.Millisecond
	ytdlpDNSLookupTimeout    = 5 * time.Second
	trustedHomebrewPathEntry = "/opt/homebrew/bin:/usr/local/bin"
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

func (m *Manager) isActiveRunToken(id string, token uint64) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	current, ok := m.activeCancels[id]
	return ok && current.token == token
}

func (m *Manager) hasActiveRun(id string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.activeCancels[id]
	return ok
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
		_ = os.RemoveAll(staging)
		m.failTask(id, ErrInput.Error(), "")
		m.importMu.Unlock()
		return
	}
	if err := m.update(id, "status", StatusRunning, "error", ""); err != nil {
		_ = os.RemoveAll(staging)
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

	var stderrTail string
	var exceededLimit bool
	runErr := m.checkYtDlpHost(runCtx, task.URL)
	if runErr == nil {
		stderrTail, exceededLimit, runErr = m.execYtDlp(runCtx, id, token, binPath, staging, args, task.MaxBytes)
	}

	m.importMu.Lock()
	defer m.importMu.Unlock()
	if !m.isActiveRunToken(id, token) {
		if !m.hasActiveRun(id) {
			if current, _, readErr := m.rowByIDUnscoped(id); errors.Is(readErr, ErrNotFound) || (readErr == nil && current.Status == StatusCancelled) {
				_ = os.RemoveAll(staging)
			}
		}
		return
	}
	m.clearTaskCancel(id, token)
	current, _, readErr := m.rowByIDUnscoped(id)
	if errors.Is(readErr, ErrNotFound) {
		_ = os.RemoveAll(staging)
		return
	}
	if readErr != nil || current.Status != StatusRunning {
		if readErr == nil && current.Status == StatusCancelled {
			_ = os.RemoveAll(staging)
		}
		return
	}
	if m.ctx.Err() != nil {
		return
	}
	if exceededLimit {
		_ = os.RemoveAll(staging)
		m.failTask(id, "download_exceeds_limit", "")
		return
	}
	if runErr != nil {
		reason := ytdlpFailureReason(runCtx, runErr, stderrTail)
		_ = os.RemoveAll(staging)
		m.failTask(id, reason, "")
		return
	}
	removePartialYtDlpFiles(staging)
	if task.MaxBytes > 0 && stagingTreeBytes(staging) > task.MaxBytes {
		_ = os.RemoveAll(staging)
		m.failTask(id, "download_exceeds_limit", "")
		return
	}
	m.importDownloadLocked(id)
	if healthy, err := m.noFailedActive(); err == nil && healthy {
		m.lowerAlert()
	}
}

func ytdlpFailureReason(runCtx context.Context, runErr error, stderrTail string) string {
	if errors.Is(runErr, webarchive.ErrBlockedAddress) {
		return webarchive.ErrBlockedAddress.Error()
	}
	if errors.Is(runCtx.Err(), context.DeadlineExceeded) {
		return "ytdlp_timeout"
	}
	if tail := sanitizeText(stderrTail); tail != "" && tail != "download_failed" {
		return tail
	}
	return "ytdlp_failed"
}

func (m *Manager) execYtDlp(ctx context.Context, taskID string, token uint64, binPath, staging string, args []string, maxBytes int64) (string, bool, error) {
	finalArgs := args
	if ffmpegPath, err := ffmpegbin.Locate(); err == nil && ffmpegPath != "" {
		finalArgs = injectYtDlpFFmpegLocation(args, ffmpegPath)
	}
	execCtx, cancelExec := context.WithCancel(ctx)
	defer cancelExec()

	cmd := exec.CommandContext(execCtx, binPath, finalArgs...)
	cmd.Dir = staging
	cmd.Env = withTrustedHomebrewPATH(os.Environ())
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
		return "", false, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return "", false, err
	}
	if err := cmd.Start(); err != nil {
		return "", false, err
	}

	var exceededMaxBytes atomic.Bool
	monitorDone := make(chan struct{})
	if maxBytes > 0 {
		go func() {
			ticker := time.NewTicker(ytdlpSizePollInterval)
			defer ticker.Stop()
			for {
				select {
				case <-monitorDone:
					return
				case <-execCtx.Done():
					return
				case <-ticker.C:
					if stagingTreeBytes(staging) > maxBytes {
						exceededMaxBytes.Store(true)
						cancelExec()
						return
					}
				}
			}
		}()
	}

	var stderrBuf boundedTail
	stderrBuf.limit = maxYtDlpStderrBytes
	var streamWG sync.WaitGroup
	streamWG.Add(2)
	go func() {
		defer streamWG.Done()
		m.consumeYtDlpOutput(taskID, token, stdout, nil)
	}()
	go func() {
		defer streamWG.Done()
		m.consumeYtDlpOutput(taskID, token, stderr, &stderrBuf)
	}()

	streamWG.Wait()
	waitErr := cmd.Wait()
	close(monitorDone)
	return stderrBuf.String(), exceededMaxBytes.Load(), waitErr
}

func (m *Manager) consumeYtDlpOutput(taskID string, token uint64, r io.Reader, tail *boundedTail) {
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
		if m.isActiveRunToken(taskID, token) {
			_ = m.updateRunnerProgress(taskID, total, completed)
		}
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
		if filepath.Ext(name) == ".part" || filepath.Ext(name) == ".ytdl" {
			_ = os.Remove(filepath.Join(staging, name))
		}
	}
}
