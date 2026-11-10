package downloads

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Start explicitly starts the engine. Normal callers use Create/Action, which
// start it on demand. Serialize startup with mutations and idle shutdown.
func (m *Manager) Start() error {
	m.importMu.Lock()
	defer m.importMu.Unlock()
	return m.startLocked()
}

func (m *Manager) resolveBinaryLocked() string {
	if m.opts.Binary != "" {
		return m.opts.Binary
	}
	if m.opts.LocateBinary != nil {
		if path, version, err := m.opts.LocateBinary(); err == nil && path != "" {
			m.opts.Binary = path
			if m.version == "" && version != "" {
				m.version = version
			}
			return path
		}
	}
	return ""
}

func (m *Manager) startLocked() error {
	m.mu.Lock()
	binary := m.resolveBinaryLocked()
	m.mu.Unlock()
	if binary == "" {
		return ErrNotAvailable
	}
	staging := filepath.Join(m.opts.DataDir, "downloads-staging")
	if err := os.MkdirAll(staging, 0o700); err != nil {
		return err
	}
	port, err := freeLoopbackPort()
	if err != nil {
		return err
	}
	secret, err := randomToken()
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.ctx.Err() != nil {
		return ErrNotAvailable
	}
	if m.rpc != nil {
		return nil
	}
	cmd := exec.Command(m.opts.Binary,
		"--no-conf=true",
		"--enable-rpc",
		"--rpc-listen-port="+strconv.Itoa(port),
		"--rpc-secret="+secret,
		"--rpc-listen-all=false",
		"--dir="+staging,
		"--max-concurrent-downloads=3",
		"--max-connection-per-server=4",
		"--split=4",
		"--continue=true",
		"--allow-overwrite=false",
		"--auto-file-renaming=false",
		"--seed-time=0",
		"--quiet=true",
		"--stop-with-process="+strconv.Itoa(os.Getpid()),
	)
	if err := cmd.Start(); err != nil {
		return err
	}
	m.cmd = cmd
	m.processDone = make(chan struct{})
	done := m.processDone
	m.rpc = NewRPC(port, secret)
	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		_ = cmd.Wait()
		close(done)
	}()
	rpcCtx, cancel := context.WithTimeout(m.ctx, 8*time.Second)
	version, rpcErr := m.awaitReady(rpcCtx)
	cancel()
	if rpcErr != nil {
		m.stopLocked()
		return fmt.Errorf("%w: aria2 rpc not ready", ErrNotAvailable)
	}
	m.available = true
	m.version = version
	m.idleSince = time.Now()
	m.wg.Add(1)
	go m.pollLoop(m.rpc, done)
	return nil
}

// The v1 download publisher is not root-scoped and has no user-ledger
// reservation. An aria2 payload can also contain nested source names even
// when the requested destination is "."; check both at publication time.
func personalStorageDestination(name string) bool {
	return strings.EqualFold(name, "Users") ||
		(len(name) > 6 && name[5] == '/' && strings.EqualFold(name[:5], "Users"))
}

func (m *Manager) awaitReady(ctx context.Context) (string, error) {
	ticker := time.NewTicker(150 * time.Millisecond)
	defer ticker.Stop()
	for {
		if version, err := m.rpc.GetVersion(ctx); err == nil {
			return version, nil
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-m.processDone:
			return "", errors.New("aria2 exited before RPC was ready")
		case <-ticker.C:
		}
	}
}

// Close stops the supervised process and the poller, then closes the journal.
func (m *Manager) Close() error {
	m.cancel()
	m.mu.Lock()
	m.stopLocked()
	m.mu.Unlock()
	m.wg.Wait()
	m.importMu.Lock()
	defer m.importMu.Unlock()
	return m.db.Close()
}

func (m *Manager) stopLocked() {
	if m.cmd != nil && m.cmd.Process != nil {
		_ = m.cmd.Process.Kill()
		// Always reap startup failures and idle engines before dropping handles.
		<-m.processDone
	}
	m.processDone = nil
	m.available = false
	m.rpc = nil
	m.cmd = nil
}

// Available reports whether the download center can run on this machine.
func (m *Manager) Available() (bool, string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.ctx.Err() != nil {
		return false, "aria2_not_running"
	}
	if m.resolveBinaryLocked() == "" {
		return false, "aria2_not_installed"
	}
	return true, "" // installed, including a deliberately idle engine
}

func (m *Manager) Version() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.version
}

// ValidateURL enforces the protocol allowlist. file://, data:, userinfo and
// other exotic schemes never reach aria2.
func ValidateURL(raw string) error {
	if len(raw) > maxURLLength {
		return ErrInput
	}
	if strings.HasPrefix(raw, "magnet:") {
		if magnetPattern.MatchString(raw) {
			return nil
		}
		return ErrInput
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return ErrInput
	}
	switch parsed.Scheme {
	case "http", "https", "ftp":
	default:
		return ErrInput
	}
	if parsed.Host == "" || parsed.User != nil {
		return ErrInput
	}
	if _, _, err := net.SplitHostPort(hostnamePort(parsed)); err != nil {
		// Hosts without an explicit port are fine; only malformed
		// bracket literals or ports fail SplitHostPort on the synthetic
		// form below.
		if parsed.Port() != "" {
			return ErrInput
		}
	}
	return nil
}

func hostnamePort(parsed *url.URL) string {
	if parsed.Port() != "" {
		return parsed.Host
	}
	return net.JoinHostPort(parsed.Hostname(), "80")
}

var magnetPattern = regexp.MustCompile(`^magnet:\?xt=urn:btih:[A-Za-z0-9]{32,40}(&[A-Za-z0-9_.%*-]+=[^&]*)*$`)

// ValidateDestination accepts "." (share root) or a relative in-share path.
func ValidateDestination(destination string) error {
	if destination == "." {
		return nil
	}
	if destination == "" || len(destination) > maxDestinationLen ||
		strings.HasPrefix(destination, "/") || strings.Contains(destination, "\\") ||
		strings.Contains(destination, "..") {
		return ErrInput
	}
	for _, segment := range strings.Split(destination, "/") {
		if segment == "" || segment == "." {
			return ErrInput
		}
	}
	return nil
}

func (m *Manager) isAvailable() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.available && m.rpc != nil
}

func (m *Manager) stagingDir(id string) string {
	return filepath.Join(m.opts.DataDir, "downloads-staging", id)
}

func (m *Manager) withRPC(fn func(context.Context, *RPC)) {
	m.mu.Lock()
	rpc := m.rpc
	m.mu.Unlock()
	if rpc == nil {
		return
	}
	ctx, cancel := context.WithTimeout(m.ctx, 4*time.Second)
	defer cancel()
	fn(ctx, rpc)
}

func freeLoopbackPort() (int, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		return 0, err
	}
	return port, nil
}

func randomToken() (string, error) {
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	const hexDigits = "0123456789abcdef"
	out := make([]byte, len(buffer)*2)
	for i, b := range buffer {
		out[i*2] = hexDigits[b>>4]
		out[i*2+1] = hexDigits[b&0xF]
	}
	return string(out), nil
}

func sanitizeError(err error) string {
	return sanitizeText(err.Error())
}

// sanitizeText keeps journal payloads bounded and strips path-like content
// so a hostile server response cannot smuggle staging paths into the UI.
func sanitizeText(message string) string {
	const limit = 160
	clean := strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			return r
		case r == ' ', r == '-', r == '_', r == '.', r == ',', r == ':':
			return r
		default:
			return ' '
		}
	}, message)
	clean = strings.Join(strings.Fields(clean), " ")
	if len(clean) > limit {
		clean = clean[:limit]
	}
	if clean == "" {
		return "download_failed"
	}
	return clean
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
