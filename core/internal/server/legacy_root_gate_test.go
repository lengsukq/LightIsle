package server

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func gateTestRoot(t *testing.T) string {
	t.Helper()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	root, err := os.MkdirTemp(home, ".lightisle-legacy-gate-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	return filepath.Clean(root)
}

func TestLegacyRootGateFailsClosedAndExcludesDiskActions(t *testing.T) {
	manager, err := files.NewManager(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()

	entered := make(chan struct{})
	resume := make(chan struct{})
	// A failed assertion must also release the waiting transition. Otherwise
	// manager.Close deadlocks and hides the real regression behind test timeout.
	defer func() {
		select {
		case <-resume:
		default:
			close(resume)
		}
	}()
	transition := make(chan error, 1)
	go func() {
		transition <- manager.SetRootWithLegacyTransition(gateTestRoot(t), func() error {
			close(entered)
			<-resume
			return nil
		}, func() error { return nil })
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		close(resume)
		t.Fatal("root transition did not reach its protected callback")
	}

	var passed atomic.Int32
	handler := legacyRootTransitionGate(manager, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		passed.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	for _, path := range []string{"/api/v2/health", "/dav/"} {
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		if recorder.Code != http.StatusServiceUnavailable || !strings.Contains(recorder.Body.String(), files.ErrLegacyTransitionBusy.Error()) {
			t.Fatalf("%s during root transition = %d %s", path, recorder.Code, recorder.Body.String())
		}
	}

	for _, path := range []string{"/api/v2/admin/disks/actions", "/api/v2/roots", "/assets/app.js"} {
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		if recorder.Code != http.StatusNoContent {
			t.Fatalf("unrelated %s request was gated: %d", path, recorder.Code)
		}
	}
	if got := passed.Load(); got != 3 {
		t.Fatalf("passed requests = %d, want disk actions plus unrelated routes", got)
	}

	close(resume)
	select {
	case err := <-transition:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("root transition did not finish")
	}
}

func TestLegacyRequestGateNestsAndRootTransitionFailsFast(t *testing.T) {
	manager, err := files.NewManager(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()

	entered := make(chan struct{})
	resume := make(chan struct{})
	handler := legacyRootTransitionGate(manager, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		release, ok := manager.TryAcquireLegacyRequest()
		if !ok {
			http.Error(w, "nested gate unexpectedly denied", http.StatusInternalServerError)
			return
		}
		release()
		close(entered)
		<-resume
		w.WriteHeader(http.StatusNoContent)
	}))

	requestDone := make(chan struct{})
	go func() {
		defer close(requestDone)
		handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/api/v2/files", nil))
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		close(resume)
		t.Fatal("legacy request did not enter handler")
	}

	started := time.Now()
	err = manager.SetRootWithLegacyTransition(gateTestRoot(t), func() error {
		t.Error("idle callback ran while a legacy request was active")
		return nil
	}, func() error {
		t.Error("revocation ran while a legacy request was active")
		return nil
	})
	if !errors.Is(err, files.ErrRootBusy) {
		t.Fatalf("root transition while request active = %v", err)
	}
	if time.Since(started) > 500*time.Millisecond {
		t.Fatal("root transition waited for the active request instead of failing fast")
	}
	close(resume)
	select {
	case <-requestDone:
	case <-time.After(2 * time.Second):
		t.Fatal("legacy request did not finish")
	}
}
