// Package frpclient installs and supervises an optional, external frpc.
// Neither the server (frps) nor the client binary ships inside LightIsle.
package frpclient

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	maxTar         = 32 << 20
	maxBinary      = 50 << 20
	maxConfig      = 1 << 20
	maxExpandedTar = 128 << 20
	maxFRPRestarts = 4
)

// Tests shorten the wait; real-world restarts use increasing delays rather
// than spinning if the network, frps or the local binary keeps failing.
var frpRestartBackoff = 5 * time.Second

var (
	ErrBusy       = errors.New("frp_busy")
	ErrNotFound   = errors.New("frpc_not_installed")
	ErrConfig     = errors.New("frpc_config_incomplete")
	ErrNoProxy    = errors.New("frpc_no_proxy_configured")
	ErrUnsafePath = errors.New("frpc_unsafe_path")
	ErrVersion    = errors.New("frpc_version_unavailable")
)

const ConfigTemplate = `# LightIsle 仅管理 frpc 客户端；你必须有自己的 frps 服务端。
# 修改占位值后再启动。保存后需手动重启 frpc 才会生效。
serverAddr = "REPLACE_WITH_FRPS_HOST"
serverPort = 7000
auth.method = "token"
auth.token = "REPLACE_WITH_FRPS_TOKEN"

# 以下仅是示例，确认公网暴露风险后取消注释并修改端口。
# 如果本机 LightIsle 监听 HTTP，不应直接映射至互联网；优先 HTTPS。
# [[proxies]]
# name = "lightisle"
# type = "tcp"
# localIP = "127.0.0.1"
# localPort = 16666
# remotePort = 16666
`

type State struct {
	Status            string `json:"status"`     // process state, not an assertion that frps is reachable
	Connection        string `json:"connection"` // disconnected/connecting/connected/degraded/failed
	ProxyCount        int    `json:"proxyCount"`
	ProxyReady        int    `json:"proxyReady"`
	Installed         bool   `json:"installed"`
	Version           string `json:"version"`
	InstallingVersion string `json:"installingVersion,omitempty"`
	ConfigPath        string `json:"configPath"`
	BinaryPath        string `json:"binaryPath"`
	PID               int    `json:"pid,omitempty"`
	Error             string `json:"error,omitempty"`
	LastLine          string `json:"lastLine,omitempty"`
}

type Manager struct {
	mu         sync.Mutex
	ctx        context.Context
	dir        string
	cmd        *exec.Cmd
	done       chan struct{}
	install    bool
	fetching   bool
	releases   map[string]Release
	state      State
	notify     func(State)
	restarts   int
	restartSeq uint64
	startedAt  time.Time
}

func DefaultDir() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "LightIsle", "frp"), nil
}

func New(ctx context.Context, dir string, notify func(State)) *Manager {
	return &Manager{ctx: ctx, dir: dir, notify: notify, state: State{Status: "stopped"}}
}

func (m *Manager) ConfigPath() string  { return filepath.Join(m.dir, "frpc.toml") }
func (m *Manager) BinaryPath() string  { return filepath.Join(m.dir, "frpc") }
func (m *Manager) VersionPath() string { return filepath.Join(m.dir, "installed-version") }

func openRegularLocal(name string) (*os.File, os.FileInfo, error) {
	file, err := os.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		if errors.Is(err, syscall.ELOOP) {
			return nil, nil, ErrUnsafePath
		}
		return nil, nil, err
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		file.Close()
		return nil, nil, ErrUnsafePath
	}
	return file, info, nil
}

func readLocalBounded(name string, maxBytes int64) ([]byte, error) {
	file, info, err := openRegularLocal(name)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	if info.Size() > maxBytes {
		return nil, ErrConfig
	}
	data, err := io.ReadAll(io.LimitReader(file, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maxBytes {
		return nil, ErrConfig
	}
	return data, nil
}

// EnsureConfig is idempotent. Never replace an existing config, or follow
// a symlink into an arbitrary file when the user chooses "Open config".
func (m *Manager) EnsureConfig() error {
	if err := os.MkdirAll(m.dir, 0700); err != nil {
		return err
	}
	name := m.ConfigPath()
	if current, _, err := openRegularLocal(name); err == nil {
		defer current.Close()
		// Chmod the checked inode, never a symlink substituted for it.
		return current.Chmod(0600)
	} else if !os.IsNotExist(err) {
		return err
	}
	f, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if os.IsExist(err) {
		return m.EnsureConfig()
	}
	if err != nil {
		return err
	}
	_, writeErr := io.WriteString(f, ConfigTemplate)
	closeErr := f.Close()
	if writeErr != nil || closeErr != nil {
		_ = os.Remove(name)
		if writeErr != nil {
			return writeErr
		}
		return closeErr
	}
	return nil
}

func (m *Manager) installed() bool {
	st, err := os.Lstat(m.BinaryPath())
	return err == nil && st.Mode().IsRegular() && st.Mode()&0100 != 0
}

func (m *Manager) snapshotLocked() State {
	s := m.state
	s.Installed = m.installed()
	s.ConfigPath, s.BinaryPath = m.ConfigPath(), m.BinaryPath()
	s.Version = ""
	if s.Installed {
		if raw, err := readLocalBounded(m.VersionPath(), 256); err == nil {
			version := strings.TrimSpace(string(raw))
			if validVersion.MatchString("v"+version) && len(version) < 48 {
				s.Version = version
			}
		}
	}
	return s
}

func (m *Manager) Status() State {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.snapshotLocked()
}

func (m *Manager) emitLocked() {
	if m.notify != nil {
		s := m.snapshotLocked()
		go m.notify(s)
	}
}

// FetchVersions loads the official release catalog only on user request.
// Selection is matched exclusively against this private, validated catalog.
func (m *Manager) FetchVersions(ctx context.Context) ([]Release, error) {
	m.mu.Lock()
	if m.fetching {
		m.mu.Unlock()
		return nil, ErrBusy
	}
	m.fetching = true
	m.mu.Unlock()
	releases, err := fetchReleases(ctx, githubClient(), releasesAPI)
	m.mu.Lock()
	m.fetching = false
	if err == nil {
		m.releases = make(map[string]Release, len(releases))
		for _, r := range releases {
			m.releases[r.Version] = r
		}
	}
	m.mu.Unlock()
	return releases, err
}

// BeginInstall refuses a version not found in the freshly fetched official
// catalog, a missing verified asset, and upgrades while frpc is running.
func (m *Manager) BeginInstall(version string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.install || m.cmd != nil || m.state.Status == "restarting" {
		return ErrBusy
	}
	release, found := m.releases[version]
	if !found || !release.Installable || release.url == "" || !validDigest.MatchString(release.digest) {
		return ErrVersion
	}
	if runtime.GOOS != "darwin" || runtime.GOARCH != "arm64" {
		return errors.New("frpc_unsupported_platform")
	}
	m.install = true
	m.state.Status, m.state.Error = "installing", ""
	m.state.InstallingVersion = version
	m.emitLocked()
	go func() {
		err := m.download(m.ctx, release)
		m.mu.Lock()
		m.install = false
		m.state.InstallingVersion = ""
		if err != nil {
			m.state.Status, m.state.Error = "error", err.Error()
		} else {
			m.state.Status, m.state.Error = "stopped", ""
		}
		m.emitLocked()
		m.mu.Unlock()
	}()
	return nil
}

func (m *Manager) download(ctx context.Context, release Release) error {
	if err := m.EnsureConfig(); err != nil {
		return err
	}
	client := &http.Client{Timeout: 100 * time.Second, CheckRedirect: trustedRedirect}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, release.url, nil)
	if err != nil {
		return err
	}
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("frpc_download_failed: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("frpc_download_http_%d", response.StatusCode)
	}
	archive, err := os.CreateTemp(m.dir, ".frpc-release-*")
	if err != nil {
		return err
	}
	defer os.Remove(archive.Name())
	defer archive.Close()
	hash := sha256.New()
	n, err := io.Copy(io.MultiWriter(archive, hash), io.LimitReader(response.Body, maxTar+1))
	if err != nil {
		return err
	}
	if n > maxTar {
		return errors.New("frpc_download_too_large")
	}
	if hex.EncodeToString(hash.Sum(nil)) != release.digest {
		return errors.New("frpc_checksum_mismatch")
	}
	if _, err = archive.Seek(0, io.SeekStart); err != nil {
		return err
	}
	gz, err := gzip.NewReader(archive)
	if err != nil {
		return err
	}
	defer gz.Close()
	// tar.Next discards unused entries too. Bound total decompression,
	// including files that are never extracted.
	expanded := &io.LimitedReader{R: gz, N: maxExpandedTar + 1}
	tr := tar.NewReader(expanded)
	bin, err := os.CreateTemp(m.dir, ".frpc-install-*")
	if err != nil {
		return err
	}
	defer os.Remove(bin.Name())
	defer bin.Close()
	found := false
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		hdr, err := tr.Next()
		if expanded.N == 0 {
			return errors.New("frpc_expanded_archive_too_large")
		}
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		if filepath.Base(hdr.Name) != "frpc" || !hdr.FileInfo().Mode().IsRegular() {
			continue
		}
		if found || hdr.Size <= 0 || hdr.Size > maxBinary {
			return errors.New("frpc_invalid_archive")
		}
		if _, err := io.CopyN(bin, tr, hdr.Size); err != nil {
			return err
		}
		found = true
	}
	if !found {
		return errors.New("frpc_binary_missing_in_archive")
	}
	if err := bin.Chmod(0700); err != nil {
		return err
	}
	if err := bin.Sync(); err != nil {
		return err
	}
	if err := bin.Close(); err != nil {
		return err
	}
	if st, err := os.Lstat(m.BinaryPath()); err == nil && !st.Mode().IsRegular() {
		return ErrUnsafePath
	} else if err != nil && !os.IsNotExist(err) {
		return err
	}
	if err := os.Rename(bin.Name(), m.BinaryPath()); err != nil {
		return err
	}
	// A sidecar survives Core restarts and avoids displaying a hard-coded
	// version for older manually installed binaries.
	tmp, err := os.CreateTemp(m.dir, ".frpc-version-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err = tmp.WriteString(release.Version + "\n"); err != nil {
		tmp.Close()
		return err
	}
	if err = tmp.Chmod(0600); err != nil {
		tmp.Close()
		return err
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), m.VersionPath())
}

func (m *Manager) Start() error {
	if err := m.EnsureConfig(); err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cmd != nil || m.install || m.state.Status == "restarting" {
		return ErrBusy
	}
	m.restartSeq++
	m.restarts = 0
	return m.startLocked()
}

// Caller owns m.mu. Both explicit Start and a generation-checked background
// recovery go through exactly the same executable and TOML validation.
func (m *Manager) startLocked() error {
	if !m.installed() {
		return ErrNotFound
	}
	b, err := readLocalBounded(m.ConfigPath(), maxConfig)
	if err != nil {
		return err
	}
	if len(b) == 0 || strings.Contains(string(b), "REPLACE_WITH_") {
		return ErrConfig
	}
	proxyCount := configuredProxyCount(string(b))
	if proxyCount == 0 {
		return ErrNoProxy
	}
	// The executable is always a single, local path, never arbitrary command
	// text supplied by a browser or configuration file.
	cmd := exec.CommandContext(m.ctx, m.BinaryPath(), "-c", m.ConfigPath())
	cmd.Env = os.Environ()
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = 4 * time.Second
	// Capture only recognized connection events. Raw output can contain
	// credentials and is NEVER persisted or forwarded to the parent App.
	watcher := &frpLogWatcher{manager: m, command: cmd}
	cmd.Stdout, cmd.Stderr = watcher, watcher
	if err := cmd.Start(); err != nil {
		m.state.Status, m.state.Error = "error", "frpc_start_failed"
		m.emitLocked()
		return err
	}
	m.cmd = cmd
	m.done = make(chan struct{})
	m.startedAt = time.Now()
	m.state.Status, m.state.PID, m.state.Error, m.state.LastLine = "running", cmd.Process.Pid, "", ""
	m.state.Connection, m.state.ProxyCount, m.state.ProxyReady = "connecting", proxyCount, 0
	m.emitLocked()
	go m.wait(cmd, m.done)
	go m.checkConnectionTimeout(cmd, m.done)
	return nil
}

func (m *Manager) checkConnectionTimeout(cmd *exec.Cmd, done <-chan struct{}) {
	select {
	case <-time.After(20 * time.Second):
		m.mu.Lock()
		if m.cmd == cmd && m.state.Connection == "connecting" {
			// Silence is not proof of failure: custom frpc log settings can
			// suppress stdout even while the server connection is healthy.
			m.state.Connection, m.state.Error = "unverified", "frpc_login_unverified"
			m.state.LastLine = "20 秒内未收到可确认连接的日志；请结合远端代理访问结果检查。"
			m.emitLocked()
		}
		m.mu.Unlock()
	case <-done:
	}
}

func (m *Manager) wait(cmd *exec.Cmd, done chan struct{}) {
	err := cmd.Wait()
	m.mu.Lock()
	if m.cmd == cmd {
		m.cmd = nil
		m.state.PID = 0
		m.state.Connection = "disconnected"
		if m.state.Error != "" {
			// Preserve a more useful, sanitized authentication/connection cause.
		} else if err == nil {
			m.state.Error = "frpc_exited"
		} else {
			m.state.Error = "frpc_exited_unexpectedly"
		}
		// Do not endlessly retry an invalid credential or configuration.
		// A long-lived process earns a fresh, small recovery budget; immediate
		// crash loops remain bounded. Stop() invalidates the recovery token.
		retryable := m.ctx.Err() == nil &&
			m.state.Error != "frpc_auth_failed" &&
			m.state.Error != "frpc_config_invalid" &&
			m.state.Error != "frpc_proxy_register_failed"
		if retryable && time.Since(m.startedAt) >= 2*time.Minute {
			m.restarts = 0
		}
		if retryable && m.restarts < maxFRPRestarts {
			m.restarts++
			m.state.Status = "restarting"
			m.state.LastLine = fmt.Sprintf("FRP 意外断开，正在进行第 %d/%d 次延时重启。", m.restarts, maxFRPRestarts)
			sequence := m.restartSeq
			delay := frpRestartBackoff * time.Duration(m.restarts)
			go m.retryAfter(sequence, delay)
		} else {
			m.state.Status = "error"
		}
		m.emitLocked()
	}
	m.mu.Unlock()
	close(done)
}

func (m *Manager) retryAfter(sequence uint64, delay time.Duration) {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-timer.C:
	case <-m.ctx.Done():
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.restartSeq != sequence || m.state.Status != "restarting" ||
		m.cmd != nil || m.install || m.ctx.Err() != nil {
		return
	}
	if err := m.startLocked(); err != nil {
		m.state.Status = "error"
		m.state.Connection = "disconnected"
		m.state.Error = "frpc_restart_failed"
		m.emitLocked()
	}
}

func (m *Manager) Stop() State {
	m.mu.Lock()
	m.restartSeq++
	m.restarts = 0
	cmd, done := m.cmd, m.done
	m.cmd = nil
	m.state.Status, m.state.PID, m.state.Error = "stopped", 0, ""
	m.state.Connection, m.state.ProxyCount, m.state.ProxyReady, m.state.LastLine = "disconnected", 0, 0, ""
	m.emitLocked()
	m.mu.Unlock()
	if cmd != nil {
		if cmd.Cancel != nil {
			_ = cmd.Cancel()
		}
		select {
		case <-done:
		case <-time.After(6 * time.Second):
			_ = cmd.Process.Kill()
		}
	}
	return m.Status()
}
