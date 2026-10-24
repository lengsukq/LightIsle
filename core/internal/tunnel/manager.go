// Package tunnel supervises an external cloudflared child process so the
// NAS can be reached through Cloudflare Tunnel. It never bundles or
// downloads the binary: like the Docker integration, only known Homebrew
// install locations are allowed. The child dies with the Core lifecycle and
// tokens never reach logs or persisted state.
package tunnel

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Mode distinguishes the two supported connection styles.
type Mode string

const (
	ModeOff   Mode = "off"
	ModeQuick Mode = "quick"
	ModeNamed Mode = "named"
)

const (
	outputCap   = 512 * 1024
	stopGrace   = 5 * time.Second
	maxRestarts = 3
	logLineCap  = 200
)

// restartBackoff is a var so tests can shrink the delay.
var restartBackoff = 4 * time.Second

var (
	ErrBusy     = errors.New("tunnel_already_running")
	ErrNoBinary = errors.New("cloudflared_not_found")
	ErrInvalid  = errors.New("invalid_tunnel_request")
	quickURL    = regexp.MustCompile(`https://[a-z0-9-]+\.trycloudflare\.com`)

	// Only known Homebrew prefixes are probed, mirroring the Docker runtime.
	binaryCandidates = []string{"/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"}
)

// State is the IPC-facing snapshot of the supervisor.
type State struct {
	Mode        Mode   `json:"mode"`
	Status      string `json:"status"` // stopped/starting/online/error
	URL         string `json:"url,omitempty"`
	TunnelID    string `json:"tunnelId,omitempty"`
	TunnelName  string `json:"tunnelName,omitempty"`
	Binary      string `json:"binary,omitempty"`
	BinaryFound bool   `json:"binaryFound"`
	PID         int    `json:"pid,omitempty"`
	Error       string `json:"error,omitempty"`
	LastLine    string `json:"lastLine,omitempty"`
	StartedAt   int64  `json:"startedAt,omitempty"`
}

// Manager owns at most one cloudflared child process.
type Manager struct {
	mu        sync.Mutex
	ctx       context.Context // core lifecycle; the child never outlives it
	targetURL string
	binary    string
	checked   bool

	cmd        *exec.Cmd
	exited     chan struct{}
	state      State
	logBuf     []string
	mode       Mode
	namedToken string
	restarts   int
	onAlert    func(active bool) // true = disconnected unexpectedly, false = back online
	notify     func(State)
}

func New(ctx context.Context, targetURL string) *Manager {
	return &Manager{
		ctx:       ctx,
		targetURL: targetURL,
		state:     State{Mode: ModeOff, Status: "stopped"},
	}
}

// SetHooks wires the alert-center and IPC push integrations. Callbacks run
// on the supervisor goroutine and must be cheap.
func (m *Manager) SetHooks(onAlert func(active bool), notify func(State)) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.onAlert, m.notify = onAlert, notify
}

func (m *Manager) detectBinary() (string, bool) {
	if m.checked {
		return m.binary, m.binary != ""
	}
	for _, candidate := range binaryCandidates {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0111 != 0 {
			m.binary, m.checked = candidate, true
			return m.binary, true
		}
	}
	m.binary, m.checked = "", true
	return "", false
}

func (m *Manager) Status() State {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.snapshotLocked()
}

func (m *Manager) snapshotLocked() State {
	state := m.state
	state.Binary, state.BinaryFound = m.detectBinary()
	if len(m.logBuf) > 0 {
		state.LastLine = m.logBuf[len(m.logBuf)-1]
	}
	return state
}

// StartQuick launches a free trycloudflare tunnel. The URL is random, only
// valid for this run and parsed from the child's output.
func (m *Manager) StartQuick() (State, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.restarts = 0
	return m.startLocked(ModeQuick, "", "", "")
}

// StartNamed runs a remotely-managed tunnel by token. The token is held in
// memory only and forgotten on Stop.
func (m *Manager) StartNamed(tunnelID, tunnelName, token string) (State, error) {
	if tunnelID == "" || token == "" || len(token) > 8192 {
		return m.Status(), ErrInvalid
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.restarts = 0
	return m.startLocked(ModeNamed, tunnelID, tunnelName, token)
}

// startLocked requires m.mu. User-initiated starts reset the restart
// budget; the supervisor's crash restarts deliberately do not.
func (m *Manager) startLocked(mode Mode, tunnelID, tunnelName, token string) (State, error) {
	if m.cmd != nil {
		return m.snapshotLocked(), ErrBusy
	}
	binary, ok := m.detectBinary()
	if !ok {
		m.state = State{Mode: ModeOff, Status: "error", Error: "cloudflared_not_found"}
		return m.snapshotLocked(), ErrNoBinary
	}
	var arguments []string
	switch mode {
	case ModeQuick:
		arguments = []string{"tunnel", "--url", m.targetURL, "--no-autoupdate"}
	case ModeNamed:
		arguments = []string{"tunnel", "run", "--no-autoupdate", "--token", token}
	default:
		return m.snapshotLocked(), ErrInvalid
	}
	cmd := exec.CommandContext(m.ctx, binary, arguments...)
	// Proxy variables are stripped on purpose: a system proxy (Clash etc.)
	// hijacking the argotunnel control channel is the most common failure
	// mode for tunnels behind desktop proxy tools.
	cmd.Env = scrubbedEnv()
	cmd.Stdout = &lineWriter{manager: m}
	cmd.Stderr = &lineWriter{manager: m}
	// SIGTERM first; CommandContext escalates to SIGKILL after WaitDelay.
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = stopGrace
	if err := cmd.Start(); err != nil {
		m.state = State{Mode: ModeOff, Status: "error", Error: "cloudflared_start_failed"}
		return m.snapshotLocked(), err
	}
	m.cmd = cmd
	m.exited = make(chan struct{})
	m.mode = mode
	m.logBuf = nil
	if mode == ModeNamed {
		m.namedToken = token
	}
	m.state = State{
		Mode: mode, Status: "starting", Binary: binary, PID: cmd.Process.Pid,
		TunnelID: tunnelID, TunnelName: tunnelName, StartedAt: time.Now().Unix(),
	}
	go m.supervise(cmd, mode)
	return m.snapshotLocked(), nil
}

// supervise waits for the child: restart on unexpected exits with a bounded
// backoff, and surface state changes through the hooks.
func (m *Manager) supervise(cmd *exec.Cmd, mode Mode) {
	exited := m.exited
	defer close(exited)
	waitErr := cmd.Wait()

	m.mu.Lock()
	if m.cmd != cmd || m.ctx.Err() != nil {
		// Superseded by Stop()/restart or the Core is shutting down.
		m.mu.Unlock()
		return
	}
	m.cmd = nil
	if m.restarts >= maxRestarts {
		m.state.Status = "error"
		m.state.Error = summarizeExit(waitErr)
		m.emitLocked()
		m.mu.Unlock()
		return
	}
	m.restarts++
	delay := restartBackoff * time.Duration(m.restarts)
	m.state.Status = "starting"
	m.state.Error = summarizeExit(waitErr)
	m.emitLocked()
	if m.onAlert != nil {
		m.onAlert(true)
	}
	m.mu.Unlock()

	select {
	case <-m.ctx.Done():
		return
	case <-time.After(delay):
	}
	m.mu.Lock()
	if _, err := m.startLocked(mode, m.state.TunnelID, m.state.TunnelName, m.namedToken); err != nil {
		m.state.Status = "error"
		m.state.Error = "cloudflared_restart_failed"
		m.emitLocked()
	}
	m.mu.Unlock()
}

func summarizeExit(err error) string {
	if err == nil {
		return "cloudflared_exited_unexpectedly"
	}
	text := err.Error()
	if len(text) > logLineCap {
		text = text[:logLineCap]
	}
	return text
}

// handleLine is the single output sink for the child process.
func (m *Manager) handleLine(line string) {
	line = strings.TrimSpace(line)
	if line == "" {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(line) > logLineCap {
		line = line[:logLineCap]
	}
	m.logBuf = append(m.logBuf, line)
	if len(m.logBuf) > 20 {
		m.logBuf = m.logBuf[len(m.logBuf)-20:]
	}
	if m.state.Mode == ModeQuick && m.state.URL == "" {
		if url := quickURL.FindString(line); url != "" {
			m.state.URL = url
		}
	}
	if m.state.Status == "starting" {
		ready := m.state.URL != "" && m.state.Mode == ModeQuick ||
			m.state.Mode == ModeNamed && strings.Contains(line, "Registered tunnel connection")
		if ready {
			m.state.Status = "online"
			// A connection that stayed healthy for a while earns a fresh
			// restart budget; instant flap loops must still terminate.
			if startedAt := time.Unix(m.state.StartedAt, 0); time.Since(startedAt) > time.Minute {
				m.restarts = 0
			}
			if m.onAlert != nil {
				m.onAlert(false)
			}
			m.emitLocked()
		}
	}
}

func (m *Manager) emitLocked() {
	if m.notify != nil {
		go m.notify(m.snapshotLocked())
	}
}

// Stop terminates the tunnel and forgets the in-memory token. A manual stop
// is deliberate, so it does not raise a disconnection alert.
func (m *Manager) Stop() State {
	m.mu.Lock()
	cmd, exited := m.cmd, m.exited
	m.cmd = nil
	m.namedToken = ""
	m.restarts = 0
	m.state = State{Mode: ModeOff, Status: "stopped", TunnelID: m.state.TunnelID, TunnelName: m.state.TunnelName}
	m.emitLocked()
	m.mu.Unlock()
	if cmd != nil && cmd.Cancel != nil {
		_ = cmd.Cancel()
		select {
		case <-exited:
		case <-time.After(stopGrace + 2*time.Second):
			_ = cmd.Process.Kill()
		}
	}
	return m.Status()
}

// scrubbedEnv builds a minimal, proxy-free environment for the child.
func scrubbedEnv() []string {
	keep := []string{"PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME"}
	env := make([]string, 0, len(keep))
	for _, name := range keep {
		if value, ok := os.LookupEnv(name); ok {
			env = append(env, name+"="+value)
		}
	}
	return env
}

// lineWriter feeds supervisor parsing with a hard output cap.
type lineWriter struct {
	manager *Manager
	written int
}

func (w *lineWriter) Write(p []byte) (int, error) {
	w.written += len(p)
	if w.written > outputCap {
		return 0, errors.New("tunnel output limit exceeded")
	}
	for _, line := range strings.Split(string(p), "\n") {
		w.manager.handleLine(line)
	}
	return len(p), nil
}
