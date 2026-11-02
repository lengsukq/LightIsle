package frpclient

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func TestProxyCountIgnoresCommentedExamples(t *testing.T) {
	config := "# [[proxies]]\nserverAddr = \"host\"\n[[proxies]]\nname = \"one\"\n  [[proxies]]  \n"
	if got := configuredProxyCount(config); got != 2 {
		t.Fatalf("expected two enabled proxies, got %d", got)
	}
}

func TestConnectionEventsNeverExposeFrpcLogs(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m := New(ctx, t.TempDir(), nil)
	if err := m.EnsureConfig(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(m.ConfigPath(), []byte("serverAddr = \"example.invalid\"\n[[proxies]]\nname = \"one\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	const secret = "SENSITIVE-DO-NOT-EXPOSE"
	script := "#!/bin/sh\necho 'login to server success " + secret + "'\necho '[one] start proxy success " + secret + "'\nsleep 2\n"
	if err := os.WriteFile(m.BinaryPath(), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	if err := m.Start(); err != nil {
		t.Fatal(err)
	}
	defer m.Stop()
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		s := m.Status()
		if s.Connection == "connected" && s.ProxyReady == 1 {
			if strings.Contains(s.LastLine+":"+s.Error, secret) {
				t.Fatal("raw frpc output leaked into application state")
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("login and proxy readiness were not observed: %+v", m.Status())
}

func TestFailedAuthenticationDoesNotReportConnectionSuccess(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m := New(ctx, t.TempDir(), nil)
	if err := m.EnsureConfig(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(m.ConfigPath(), []byte("serverAddr = \"example.invalid\"\n[[proxies]]\nname = \"one\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(m.BinaryPath(), []byte("#!/bin/sh\necho 'login to server failed: authentication failed user-token-should-be-hidden'\nsleep 5\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := m.Start(); err != nil {
		t.Fatal(err)
	}
	defer m.Stop()
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		s := m.Status()
		if s.Connection == "failed" {
			if s.Error != "frpc_auth_failed" || s.ProxyReady != 0 ||
				strings.Contains(s.LastLine, "user-token") {
				t.Fatalf("unsafe or misleading authentication state: %+v", s)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("authentication failure not detected: %+v", m.Status())
}
