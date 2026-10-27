package server

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestIdleRootServicesRespectLeasesAndReopenPersistedData(t *testing.T) {
	f := newRootRoutingFixture(t)
	a, err := f.server.AcquireRootServices(context.Background(), f.rootA.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	b, err := f.server.AcquireRootServices(context.Background(), f.rootB.ID)
	if err != nil {
		t.Fatal(err)
	}
	oldB := b.Services
	if err := os.WriteFile(filepath.Join(f.pathB, "kept.txt"), []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	b.Close()
	if err := f.server.releaseIdleRuntimes(time.Now().Add(rootRuntimeIdleTTL + time.Minute)); err != nil {
		t.Fatal(err)
	}
	f.server.mu.Lock()
	count := len(f.server.runtimes)
	retained := f.server.runtimes[f.rootA.ID]
	f.server.mu.Unlock()
	if count != 1 || retained == nil {
		t.Fatal("an active lease must pin only its own runtime")
	}
	reopened, err := f.server.AcquireRootServices(context.Background(), f.rootB.ID)
	if err != nil {
		t.Fatal(err)
	}
	if reopened.Services == oldB {
		t.Fatal("idle services were retained")
	}
	reopened.Close()
	data, err := os.ReadFile(filepath.Join(f.pathB, "kept.txt"))
	if err != nil || string(data) != "original" {
		t.Fatalf("eviction affected original data: %q %v", data, err)
	}
	denied := f.call(f.member, http.MethodGet, rootRoute(f.rootB.ID, "/files"), "")
	if denied.Code != http.StatusNotFound {
		t.Fatalf("root retirement changed member isolation: %d %s", denied.Code, denied.Body.String())
	}
	a.Close()
	if err := f.server.releaseIdleRuntimes(time.Now().Add(rootRuntimeIdleTTL + time.Minute)); err != nil {
		t.Fatal(err)
	}
	f.server.mu.Lock()
	count = len(f.server.runtimes)
	f.server.mu.Unlock()
	if count != 0 {
		t.Fatalf("idle roots retained: %d", count)
	}
}

func TestRootRetirementConcurrentWithCheckout(t *testing.T) {
	f := newRootRoutingFixture(t)
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 15; j++ {
				l, err := f.server.AcquireRootServices(context.Background(), f.rootA.ID)
				if err != nil {
					t.Error(err)
					return
				}
				_, _, err = l.Services.Files.Page(".", "", 10)
				if err != nil {
					t.Error(fmt.Errorf("active runtime closed: %w", err))
				}
				l.Close()
			}
		}()
	}
	for i := 0; i < 15; i++ {
		if err := f.server.releaseIdleRuntimes(time.Now().Add(time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	wg.Wait()
}

func TestIdleRootServicesDoNotInterruptBackgroundScan(t *testing.T) {
	f := newRootRoutingFixture(t)
	if err := os.WriteFile(filepath.Join(f.pathA, "blocked.heic"), []byte("worker input"), 0600); err != nil {
		t.Fatal(err)
	}
	l, err := f.server.AcquireRootServices(context.Background(), f.rootA.ID)
	if err != nil {
		t.Fatal(err)
	}
	worker := newBlockingRootMediaWorker()
	l.Services.Gallery.SetMediaWorker(worker)
	l.Close()
	started := f.call(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/photos/scan"), "")
	if started.Code != http.StatusAccepted {
		t.Fatal(started.Body.String())
	}
	select {
	case <-worker.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("scan did not start")
	}
	if err := f.server.releaseIdleRuntimes(time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if !f.services[f.rootA.ID].Gallery.Status().Running {
		t.Fatal("idle sweep cancelled scan")
	}
}
