//go:build darwin && arm64

package main

import (
	"context"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestMediaReconcilerRetriesChangesDuringActiveScan(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var attempts atomic.Int64
	first := make(chan struct{})
	retried := make(chan struct{})
	reconciler := newMediaReconciler(func() bool {
		if attempts.Add(1) == 1 {
			close(first)
			return true // media library was scanning
		}
		select {
		case <-retried:
		default:
			close(retried)
		}
		return false
	})
	reconciler.startup = time.Hour
	reconciler.periodic = time.Hour
	reconciler.retry = 10 * time.Millisecond
	done := make(chan struct{})
	go func() { reconciler.Run(ctx); close(done) }()
	for i := 0; i < 50; i++ {
		reconciler.Request()
	}
	select {
	case <-first:
	case <-time.After(time.Second):
		t.Fatal("scan not requested")
	}
	select {
	case <-retried:
	case <-time.After(time.Second):
		t.Fatal("busy scan dropped pending change")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("reconciler did not stop")
	}
	if got := attempts.Load(); got < 2 || got > 4 {
		t.Fatalf("scan attempts unbounded or missing: %d", got)
	}
}

func TestMediaReconcilerDoesNotRestartFinishedLibraryWhileAnotherIsBusy(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var galleryStarts, cinemaStarts atomic.Int64
	completed := make(chan struct{})
	reconciler := newMediaReconciler(
		func() bool {
			if galleryStarts.Add(1) < 3 {
				return true
			}
			select {
			case <-completed:
			default:
				close(completed)
			}
			return false
		},
		func() bool { cinemaStarts.Add(1); return false },
	)
	reconciler.startup = time.Hour
	reconciler.periodic = time.Hour
	reconciler.retry = 10 * time.Millisecond
	stopped := make(chan struct{})
	go func() { reconciler.Run(ctx); close(stopped) }()
	reconciler.Request()
	select {
	case <-completed:
	case <-time.After(time.Second):
		t.Fatal("busy gallery scan never retried")
	}
	if got := cinemaStarts.Load(); got != 1 {
		t.Fatalf("cinema restarted while gallery was busy: %d", got)
	}
	cancel()
	<-stopped
}
func TestMediaReconcilerIdleDoesNotRetry(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var attempts atomic.Int64
	reconciler := newMediaReconciler(func() bool { attempts.Add(1); return false })
	reconciler.startup = time.Hour
	reconciler.periodic = time.Hour
	reconciler.retry = 10 * time.Millisecond
	finished := make(chan struct{})
	go func() { reconciler.Run(ctx); close(finished) }()
	reconciler.Request()
	deadline := time.Now().Add(time.Second)
	for attempts.Load() < 1 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got := attempts.Load(); got != 1 {
		t.Fatalf("unexpected first scan count %d", got)
	}
	time.Sleep(50 * time.Millisecond)
	if got := attempts.Load(); got != 1 {
		t.Fatalf("spurious retry: %d", got)
	}
	cancel()
	<-finished
}

func TestShareReconnectImmediatelyReconcilesChangesMadeWhileOffline(t *testing.T) {
	temp := t.TempDir()
	share := filepath.Join(temp, "SharedFiles")
	detached := filepath.Join(temp, "offline-volume")
	if err := os.Mkdir(share, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(share, detached); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(detached, "added-while-offline.jpg"), []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(detached, share); err != nil {
		t.Fatal(err)
	}

	var online atomic.Bool
	observed := make(chan string, 2)
	start := func(module string) func() bool {
		return func() bool {
			if !online.Load() {
				return false
			}
			if _, err := os.Stat(filepath.Join(share, "added-while-offline.jpg")); err == nil {
				observed <- module
			}
			return false
		}
	}
	reconciler := newMediaReconciler(start("photos"), start("cinema"))
	reconciler.startup = time.Hour
	reconciler.periodic = time.Hour
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { reconciler.Run(ctx); close(done) }()

	// The temporary root changed while detached, so a new FSEvents watcher
	// cannot replay this file creation. A successful explicit reconnect must
	// cause both libraries to run a full reconciliation immediately.
	select {
	case module := <-observed:
		t.Fatalf("offline change was scanned before reconnect: %s", module)
	default:
	}
	online.Store(true)
	requestMediaReconciliationAfterShareOnline(reconciler)
	seen := map[string]bool{}
	for i := 0; i < 2; i++ {
		select {
		case module := <-observed:
			seen[module] = true
		case <-time.After(time.Second):
			t.Fatalf("reconnect did not reconcile both media libraries: %v", seen)
		}
	}
	if !seen["photos"] || !seen["cinema"] {
		t.Fatalf("missing full reconciliation after reconnect: %v", seen)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("reconciler did not stop")
	}
}
