package downloads

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestOnDemandEngineIdleRestartAndCrash(t *testing.T) {
	dir := t.TempDir()
	store, err := files.Open(filepath.Join(dir, "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	opts := testOptions(t, dir, store)
	opts.Binary = realAria2Path(t)
	m, err := New(opts)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	if available, reason := m.Available(); !available || reason != "" {
		t.Fatalf("idle availability: %v %q", available, reason)
	}
	if m.cmd != nil || m.rpc != nil {
		t.Fatal("opening history must not start an engine")
	}
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, "local payload") }))
	defer source.Close()
	task, err := m.Create(7, source.URL+"/file.txt", ".", 0)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		current, err := m.taskByID(task.ID, 7)
		if err != nil {
			t.Fatal(err)
		}
		if current.Status == StatusCompleted {
			break
		}
		if current.Status == StatusFailed {
			t.Fatalf("download failed: %+v", current)
		}
		time.Sleep(25 * time.Millisecond)
	}
	current, _ := m.taskByID(task.ID, 7)
	if current.Status != StatusCompleted {
		t.Fatalf("not published: %+v", current)
	}
	m.mu.Lock()
	done := m.processDone
	m.mu.Unlock()
	// Advance the idle clock without a five-minute sleep.
	if !m.stopIfIdle(time.Now().Add(idleProcessTTL + time.Minute)) {
		t.Fatal("terminal tasks should allow idle shutdown")
	}
	<-done
	if available, _ := m.Available(); !available {
		t.Fatal("idle must remain available for a new request")
	}
	next, err := m.Create(7, source.URL+"/next.txt", ".", 0)
	if err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		row, gid, err := m.rowByID(next.ID, 7)
		if err != nil {
			t.Fatal(err)
		}
		if row.Status == StatusRunning && gid != "" {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	m.mu.Lock()
	cmd := m.cmd
	m.mu.Unlock()
	if cmd == nil {
		t.Fatal("new request did not restart aria2")
	}
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		m.mu.Lock()
		stopped := m.cmd == nil
		m.mu.Unlock()
		if stopped {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	m.mu.Lock()
	stopped := m.cmd == nil
	m.mu.Unlock()
	if !stopped {
		t.Fatal("crashed engine was retained")
	}
	next, err = m.taskByID(next.ID, 7)
	if err != nil {
		t.Fatal(err)
	}
	if next.Status != StatusFailed || next.Error != "download_restarted" {
		t.Fatalf("crash must expose retryable failure: %+v", next)
	}
	if _, err := m.Action(7, next.ID, "retry"); err != nil {
		t.Fatalf("restart after crash: %v", err)
	}
}

func TestIdleShutdownPinsQueuedPausedAndPublishingTasks(t *testing.T) {
	dir := t.TempDir()
	store, err := files.Open(filepath.Join(dir, "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	m, err := New(testOptions(t, dir, store))
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	for _, status := range []string{StatusQueued, StatusPaused, StatusRunning} {
		if _, err := m.db.Exec(`INSERT OR REPLACE INTO download_tasks(id,owner,url,destination,status,phase,created_at,updated_at) VALUES('pin',7,'https://example.org/x','.',?,?,1,1)`, status, phasePublishing); err != nil {
			t.Fatal(err)
		}
		if m.stopIfIdle(time.Now().Add(time.Hour)) {
			t.Fatalf("evicted %s task", status)
		}
	}
}

func TestStartupFailureReapsProcess(t *testing.T) {
	dir := t.TempDir()
	store, err := files.Open(filepath.Join(dir, "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	pidFile := filepath.Join(dir, "pid")
	script := filepath.Join(dir, "not-ready")
	if err := os.WriteFile(script, []byte("#!/bin/sh\necho $$ > '"+pidFile+"'\nexec /bin/sleep 60\n"), 0700); err != nil {
		t.Fatal(err)
	}
	opts := testOptions(t, dir, store)
	opts.Binary = script
	m, err := New(opts)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	result := make(chan error, 1)
	go func() { result <- m.Start() }()
	var pid int
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		raw, _ := os.ReadFile(pidFile)
		pid, _ = strconv.Atoi(strings.TrimSpace(string(raw)))
		if pid > 0 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if pid == 0 {
		t.Fatal("child did not start")
	}
	m.cancel()
	if err := <-result; !errors.Is(err, ErrNotAvailable) {
		t.Fatalf("startup error: %v", err)
	}
	if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
		t.Fatalf("startup failure retained process %d: %v", pid, err)
	}
	if m.cmd != nil || m.rpc != nil {
		t.Fatal("failed startup retained engine handles")
	}
}

func TestStalePollCannotResurrectCancelledTask(t *testing.T) {
	dir := t.TempDir()
	store, err := files.Open(filepath.Join(dir, "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	m, err := New(testOptions(t, dir, store))
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	if _, err := m.db.Exec(`INSERT INTO download_tasks(id,owner,url,destination,status,gid,created_at,updated_at) VALUES('old',7,'https://example.org/x','.','cancelled','',1,1)`); err != nil {
		t.Fatal(err)
	}
	applied := false
	m.applyPolledStatus("old", "old-gid", func() { applied = true })
	if applied {
		t.Fatal("stale RPC result applied after cancellation")
	}
}
