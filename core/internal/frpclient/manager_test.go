package frpclient

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestConfigCreationPreservesUserChangesAndRejectsLinks(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	dir := t.TempDir()
	m := New(ctx, dir, nil)
	if err := m.EnsureConfig(); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(m.ConfigPath())
	if err != nil || !strings.Contains(string(b), "REPLACE_WITH_FRPS_HOST") {
		t.Fatalf("missing starter template: %v", err)
	}
	if stat, err := os.Stat(m.ConfigPath()); err != nil || stat.Mode().Perm() != 0600 {
		t.Fatalf("config must be owner-only: %v %v", stat, err)
	}
	if err := os.WriteFile(m.ConfigPath(), []byte("user config"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := m.EnsureConfig(); err != nil {
		t.Fatal(err)
	}
	saved, _ := os.ReadFile(m.ConfigPath())
	if string(saved) != "user config" {
		t.Fatal("existing config was overwritten")
	}
	if err := os.Remove(m.ConfigPath()); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), "outside.toml")
	if err := os.WriteFile(outside, []byte("safe"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, m.ConfigPath()); err != nil {
		t.Fatal(err)
	}
	if !errors.Is(m.EnsureConfig(), ErrUnsafePath) {
		t.Fatal("symlink not rejected")
	}
	got, _ := os.ReadFile(outside)
	if string(got) != "safe" {
		t.Fatal("symlink destination mutated")
	}
}

func TestStartRequiresVerifiedLocalExecutableAndCompletedConfig(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m := New(ctx, t.TempDir(), nil)
	if err := m.Start(); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing binary: %v", err)
	}
	if err := os.WriteFile(m.BinaryPath(), []byte("#!/bin/sh\nexec /bin/sleep 30\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := m.Start(); !errors.Is(err, ErrConfig) {
		t.Fatalf("placeholder configuration accepted: %v", err)
	}
	if err := os.WriteFile(m.ConfigPath(), []byte("serverAddr = \"my-frps.example\"\nserverPort = 7000\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := m.Start(); !errors.Is(err, ErrNoProxy) {
		t.Fatalf("configuration without proxies accepted: %v", err)
	}
	if err := os.WriteFile(m.ConfigPath(), []byte("serverAddr = \"my-frps.example\"\nserverPort = 7000\n[[proxies]]\nname = \"test\"\ntype = \"tcp\"\nlocalPort = 16666\nremotePort = 16666\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if s := m.Status(); s.Status != "stopped" || s.ProxyCount != 1 {
		t.Fatalf("stopped status did not report configured proxyCount=1 for auto-restore: %+v", s)
	}
	if err := m.Start(); err != nil {
		t.Fatal(err)
	}
	if s := m.Status(); s.Status != "running" || s.PID == 0 {
		t.Fatalf("not running: %+v", s)
	}
	if err := m.Start(); !errors.Is(err, ErrBusy) {
		t.Fatalf("duplicate start: %v", err)
	}
	if s := m.Stop(); s.Status != "stopped" || s.PID != 0 || s.ProxyCount != 1 {
		t.Fatalf("not stopped or lost configured proxyCount: %+v", s)
	}
}

func TestUnexpectedExitIsNotReportedAsOnline(t *testing.T) {
	oldBackoff := frpRestartBackoff
	frpRestartBackoff = 10 * time.Millisecond
	t.Cleanup(func() { frpRestartBackoff = oldBackoff })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m := New(ctx, t.TempDir(), nil)
	if err := m.EnsureConfig(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(m.ConfigPath(), []byte("serverAddr = \"my-frps.example\"\n[[proxies]]\nname = \"test\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(m.BinaryPath(), []byte("#!/bin/sh\nexit 5\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := m.Start(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if s := m.Status(); s.Status == "error" {
			if s.Error != "frpc_exited_unexpectedly" || s.PID != 0 {
				t.Fatalf("bad exit status: %+v", s)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("never observed process exit")
}

func configuredFRPTestManager(t *testing.T, script string) (*Manager, string, context.CancelFunc) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	m := New(ctx, t.TempDir(), nil)
	if err := m.EnsureConfig(); err != nil {
		cancel()
		t.Fatal(err)
	}
	if err := os.WriteFile(m.ConfigPath(), []byte(
		"serverAddr = \"frps.example.invalid\"\nserverPort = 7000\n[[proxies]]\nname = \"test\"\ntype = \"tcp\"\nlocalPort = 16666\nremotePort = 16666\n"), 0600); err != nil {
		cancel()
		t.Fatal(err)
	}
	if err := os.WriteFile(m.BinaryPath(), []byte(script), 0700); err != nil {
		cancel()
		t.Fatal(err)
	}
	return m, filepath.Join(m.dir, "attempts.txt"), cancel
}

func frpAttemptCount(t *testing.T, path string) int {
	t.Helper()
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return 0
	}
	if err != nil {
		t.Fatal(err)
	}
	n, err := strconv.Atoi(string(data))
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func frpScript(path string, exitAfter int) string {
	return fmt.Sprintf(`#!/bin/sh
n=0
if [ -f %q ]; then n=$(cat %q); fi
n=$((n+1))
printf '%%s' "$n" > %q
if [ "$n" -lt %d ]; then exit 5; fi
exec /bin/sleep 30
`, path, path, path, exitAfter)
}

func TestUnexpectedFRPExitRecoversWithBoundedBackoff(t *testing.T) {
	oldBackoff := frpRestartBackoff
	frpRestartBackoff = 20 * time.Millisecond
	t.Cleanup(func() { frpRestartBackoff = oldBackoff })
	m, path, cancel := configuredFRPTestManager(t, "#!/bin/sh\nexit 5\n")
	// Reinstall the test binary now that the per-instance counter path is known.
	if err := os.WriteFile(m.BinaryPath(), []byte(frpScript(path, 2)), 0700); err != nil {
		t.Fatal(err)
	}
	defer cancel()
	defer m.Stop()
	if err := m.Start(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		state := m.Status()
		if frpAttemptCount(t, path) >= 2 && state.Status == "running" && state.PID > 0 {
			if state.Connection != "connecting" {
				t.Fatalf("false connected status before frps verification: %+v", state)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("FRP failed to recover from a transient crash: state=%+v attempts=%d", m.Status(), frpAttemptCount(t, path))
}

func TestFRPManualStopCancelsPendingRestart(t *testing.T) {
	oldBackoff := frpRestartBackoff
	frpRestartBackoff = 120 * time.Millisecond
	t.Cleanup(func() { frpRestartBackoff = oldBackoff })
	m, path, cancel := configuredFRPTestManager(t, "#!/bin/sh\nexit 5\n")
	if err := os.WriteFile(m.BinaryPath(), []byte(frpScript(path, 999)), 0700); err != nil {
		t.Fatal(err)
	}
	defer cancel()
	if err := m.Start(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for m.Status().Status != "restarting" && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if m.Status().Status != "restarting" {
		t.Fatalf("unexpected status before stop: %+v", m.Status())
	}
	if state := m.Stop(); state.Status != "stopped" {
		t.Fatalf("stop during restart: %+v", state)
	}
	time.Sleep(300 * time.Millisecond)
	if got := frpAttemptCount(t, path); got != 1 {
		t.Fatalf("FRP restarted after explicit user stop: attempts=%d", got)
	}
	if m.Status().Status != "stopped" {
		t.Fatalf("manual stop was overridden by an old restart callback: %+v", m.Status())
	}
}

func TestFRPAuthenticationFailureDoesNotRestart(t *testing.T) {
	oldBackoff := frpRestartBackoff
	frpRestartBackoff = 20 * time.Millisecond
	t.Cleanup(func() { frpRestartBackoff = oldBackoff })
	m, _, cancel := configuredFRPTestManager(t,
		"#!/bin/sh\necho 'login to server failed: authorization token rejected'\nexit 5\n")
	defer cancel()
	defer m.Stop()
	if err := m.Start(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		state := m.Status()
		if state.Status == "error" {
			if state.Error != "frpc_auth_failed" || state.PID != 0 {
				t.Fatalf("authentication failure was not preserved: %+v", state)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("authentication failure triggered retry instead of actionable error: %+v", m.Status())
}

func TestStartRejectsLinkedAndOversizedConfig(t *testing.T) {
	m := New(context.Background(), t.TempDir(), nil)
	if err := os.WriteFile(m.BinaryPath(), []byte("#!/bin/sh\nexit 99\n"), 0700); err != nil {
		t.Fatal(err)
	}
	external := filepath.Join(t.TempDir(), "external.toml")
	if err := os.WriteFile(external, []byte("[[proxies]]\nname = \"example\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(external, m.ConfigPath()); err != nil {
		t.Fatal(err)
	}
	if err := m.Start(); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("linked FRP config accepted: %v", err)
	}
	if err := os.Remove(m.ConfigPath()); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(m.ConfigPath(), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(m.ConfigPath(), maxConfig+1); err != nil {
		t.Fatal(err)
	}
	if err := m.Start(); !errors.Is(err, ErrConfig) {
		t.Fatalf("oversized FRP config accepted: %v", err)
	}
}
