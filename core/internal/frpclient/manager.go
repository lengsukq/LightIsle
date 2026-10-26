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
	maxTar    = 32 << 20
	maxBinary = 50 << 20
)

var (
	ErrBusy       = errors.New("frp_busy")
	ErrNotFound   = errors.New("frpc_not_installed")
	ErrConfig     = errors.New("frpc_config_incomplete")
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
	Status            string `json:"status"` // stopped/installing/starting/running/error
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
	mu       sync.Mutex
	ctx      context.Context
	dir      string
	cmd      *exec.Cmd
	done     chan struct{}
	install  bool
	fetching bool
	releases map[string]Release
	state    State
	notify   func(State)
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

// EnsureConfig is idempotent. Never replace an existing config, or follow
// a symlink into an arbitrary file when the user chooses "Open config".
func (m *Manager) EnsureConfig() error {
	if err := os.MkdirAll(m.dir, 0700); err != nil {
		return err
	}
	name := m.ConfigPath()
	if st, err := os.Lstat(name); err == nil {
		if !st.Mode().IsRegular() {
			return ErrUnsafePath
		}
		// Editors may save the TOML with broader permissions. It contains
		// server authentication material and must stay private.
		if err := os.Chmod(name, 0600); err != nil {
			return err
		}
		return nil
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
		if raw, err := os.ReadFile(m.VersionPath()); err == nil {
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
	if m.install || m.cmd != nil {
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
	tr := tar.NewReader(gz)
	bin, err := os.CreateTemp(m.dir, ".frpc-install-*")
	if err != nil {
		return err
	}
	defer os.Remove(bin.Name())
	defer bin.Close()
	found := false
	for {
		hdr, err := tr.Next()
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
	if m.cmd != nil || m.install {
		return ErrBusy
	}
	if !m.installed() {
		return ErrNotFound
	}
	b, err := os.ReadFile(m.ConfigPath())
	if err != nil {
		return err
	}
	if len(b) == 0 || len(b) > 1<<20 || strings.Contains(string(b), "REPLACE_WITH_") {
		return ErrConfig
	}
	// The executable is always a single, local path, never arbitrary command
	// text supplied by a browser or configuration file.
	cmd := exec.CommandContext(m.ctx, m.BinaryPath(), "-c", m.ConfigPath())
	cmd.Env = os.Environ()
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = 4 * time.Second
	// Frpc may log configured credentials or URLs containing secrets.
	// Keep output out of public logs and the parent App's IPC channel.
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		m.state.Status, m.state.Error = "error", "frpc_start_failed"
		m.emitLocked()
		return err
	}
	m.cmd = cmd
	m.done = make(chan struct{})
	m.state.Status, m.state.PID, m.state.Error, m.state.LastLine = "running", cmd.Process.Pid, "", ""
	m.emitLocked()
	go m.wait(cmd, m.done)
	return nil
}

func (m *Manager) wait(cmd *exec.Cmd, done chan struct{}) {
	err := cmd.Wait()
	m.mu.Lock()
	if m.cmd == cmd {
		m.cmd = nil
		m.state.PID = 0
		m.state.Status = "error"
		if err == nil {
			m.state.Error = "frpc_exited"
		} else {
			m.state.Error = "frpc_exited_unexpectedly"
		}
		m.emitLocked()
	}
	m.mu.Unlock()
	close(done)
}

func (m *Manager) Stop() State {
	m.mu.Lock()
	cmd, done := m.cmd, m.done
	m.cmd = nil
	m.state.Status, m.state.PID, m.state.Error = "stopped", 0, ""
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
