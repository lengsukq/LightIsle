package frpclient

import (
	"context"
	"errors"
	"os"
	"path/filepath"
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
	if err := m.Start(); err != nil {
		t.Fatal(err)
	}
	if s := m.Status(); s.Status != "running" || s.PID == 0 {
		t.Fatalf("not running: %+v", s)
	}
	if err := m.Start(); !errors.Is(err, ErrBusy) {
		t.Fatalf("duplicate start: %v", err)
	}
	if s := m.Stop(); s.Status != "stopped" || s.PID != 0 {
		t.Fatalf("not stopped: %+v", s)
	}
}

func TestUnexpectedExitIsNotReportedAsOnline(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m := New(ctx, t.TempDir(), nil)
	if err := m.EnsureConfig(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(m.ConfigPath(), []byte("serverAddr = \"my-frps.example\"\n"), 0600); err != nil {
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
