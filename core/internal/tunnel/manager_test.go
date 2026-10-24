package tunnel

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeBinary writes an executable shell script pretending to be cloudflared.
func fakeBinary(t *testing.T, lines ...string) string {
	t.Helper()
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		t.Skip("shell-script fake binary needs a POSIX host")
	}
	path := filepath.Join(t.TempDir(), "cloudflared")
	script := "#!/bin/sh\n"
	for _, line := range lines {
		script += "echo '" + strings.ReplaceAll(line, "'", "") + "'\n"
	}
	script += "sleep 60\n"
	if err := os.WriteFile(path, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	return path
}

type hooks struct {
	mu     sync.Mutex
	alerts []bool
	states []State
}

func (h *hooks) alert(active bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.alerts = append(h.alerts, active)
}

func (h *hooks) notify(state State) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.states = append(h.states, state)
}

func (h *hooks) alertCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.alerts)
}

func waitFor(t *testing.T, timeout time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("condition not reached in time")
}

func TestQuickTunnelLifecycle(t *testing.T) {
	restore := binaryCandidates
	fake := fakeBinary(t, "2026-10-24 INFO +-----------------------------------------------------------+", "https://demo-random-123.trycloudflare.com")
	binaryCandidates = []string{fake}
	defer func() { binaryCandidates = restore }()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	manager := New(ctx, "http://127.0.0.1:16666")
	hooks := &hooks{}
	manager.SetHooks(hooks.alert, hooks.notify)

	state, err := manager.StartQuick()
	if err != nil {
		t.Fatalf("StartQuick: %v", err)
	}
	if state.Mode != ModeQuick || state.Status != "starting" {
		t.Fatalf("initial state = %+v", state)
	}
	if _, err := manager.StartQuick(); err != ErrBusy {
		t.Fatalf("double start err = %v, want busy", err)
	}
	waitFor(t, 5*time.Second, func() bool {
		return manager.Status().Status == "online"
	})
	online := manager.Status()
	if online.URL != "https://demo-random-123.trycloudflare.com" {
		t.Fatalf("url = %q", online.URL)
	}
	if hooks.alertCount() != 1 {
		t.Fatalf("alerts = %v, want one recovery (false)", hooks.snapshot())
	}

	final := manager.Stop()
	if final.Mode != ModeOff || final.Status != "stopped" {
		t.Fatalf("after stop = %+v", final)
	}
	waitFor(t, 5*time.Second, func() bool { return manager.Status().PID == 0 })
}

func (h *hooks) snapshot() []bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]bool(nil), h.alerts...)
}

func TestNamedTunnelReady(t *testing.T) {
	restore := binaryCandidates
	fake := fakeBinary(t, "2026-10-24 INF Registered tunnel connection connIndex=0")
	binaryCandidates = []string{fake}
	defer func() { binaryCandidates = restore }()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	manager := New(ctx, "http://127.0.0.1:16666")
	state, err := manager.StartNamed("tun123", "nas", "eyJtoken")
	if err != nil {
		t.Fatalf("StartNamed: %v", err)
	}
	if state.TunnelID != "tun123" || state.TunnelName != "nas" {
		t.Fatalf("state = %+v", state)
	}
	waitFor(t, 5*time.Second, func() bool {
		return manager.Status().Status == "online"
	})
	if _, err := manager.StartNamed("x", "y", "z"); err != ErrBusy {
		t.Fatalf("double start err = %v", err)
	}
	manager.Stop()
}

func TestStartNamedValidation(t *testing.T) {
	manager := New(context.Background(), "http://127.0.0.1:16666")
	if _, err := manager.StartNamed("", "nas", "token"); err != ErrInvalid {
		t.Errorf("empty id err = %v", err)
	}
	if _, err := manager.StartNamed("id", "nas", ""); err != ErrInvalid {
		t.Errorf("empty token err = %v", err)
	}
	if _, err := manager.StartNamed("id", "nas", strings.Repeat("x", 9000)); err != ErrInvalid {
		t.Errorf("oversized token err = %v", err)
	}
}

func TestMissingBinary(t *testing.T) {
	restore := binaryCandidates
	binaryCandidates = []string{"/nonexistent/lightisle-cloudflared"}
	defer func() { binaryCandidates = restore }()

	manager := New(context.Background(), "http://127.0.0.1:16666")
	if _, err := manager.StartQuick(); err != ErrNoBinary {
		t.Fatalf("err = %v, want no binary", err)
	}
	state := manager.Status()
	if state.BinaryFound || state.Status != "error" || state.Error != "cloudflared_not_found" {
		t.Fatalf("state = %+v", state)
	}
}

func TestUnexpectedExitRestartsThenErrors(t *testing.T) {
	restoreBinary := binaryCandidates
	restoreBackoff := restartBackoff
	restartBackoff = 20 * time.Millisecond
	defer func() { binaryCandidates, restartBackoff = restoreBinary, restoreBackoff }()

	path := filepath.Join(t.TempDir(), "cloudflared")
	script := "#!/bin/sh\necho 'https://flicker.trycloudflare.com'\n"
	if err := os.WriteFile(path, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	binaryCandidates = []string{path}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	manager := New(ctx, "http://127.0.0.1:16666")
	hooks := &hooks{}
	manager.SetHooks(hooks.alert, nil)
	if _, err := manager.StartQuick(); err != nil {
		t.Fatalf("StartQuick: %v", err)
	}

	waitFor(t, 10*time.Second, func() bool {
		state := manager.Status()
		return state.Status == "error" && state.Error != ""
	})
	if manager.Status().Status != "error" {
		t.Fatal("expected terminal error state after restart budget exhausted")
	}
	if hooks.alertCount() == 0 {
		t.Fatal("unexpected exits must raise the disconnected alert")
	}
}

func TestHandleLineSanitizesAndDetects(t *testing.T) {
	manager := New(context.Background(), "http://127.0.0.1:16666")
	manager.state.Mode = ModeQuick
	manager.state.Status = "starting"
	manager.handleLine("")
	if len(manager.logBuf) != 0 {
		t.Fatal("empty lines must be skipped")
	}
	manager.handleLine("https://abc-def-ghi.trycloudflare.com extra")
	if manager.state.URL != "https://abc-def-ghi.trycloudflare.com" {
		t.Fatalf("url = %q", manager.state.URL)
	}
	if manager.state.Status != "online" {
		t.Fatalf("quick mode with URL must be online, got %s", manager.state.Status)
	}
	long := strings.Repeat("x", 5000)
	manager.handleLine(long)
	if len(manager.logBuf[len(manager.logBuf)-1]) > logLineCap {
		t.Fatal("log line cap exceeded")
	}
}

func TestScrubbedEnvMinimal(t *testing.T) {
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:7890")
	t.Setenv("CLOUDFLARE_API_TOKEN", "secret")
	env := scrubbedEnv()
	joined := strings.Join(env, "\n")
	if strings.Contains(joined, "PROXY") || strings.Contains(joined, "CLOUDFLARE") {
		t.Errorf("proxy or cloudflare vars leaked: %s", joined)
	}
	found := false
	for _, entry := range env {
		if strings.HasPrefix(entry, "PATH=") {
			found = true
		}
	}
	if !found {
		t.Error("PATH must be preserved for the child")
	}
}
