package server

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/roots"
)

func TestNativeMediaReconciliationKeepsOtherRootsIsolatedAndFailsOffline(t *testing.T) {
	f := newRootRoutingFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if err := f.server.ReconcileRootMedia(ctx, f.rootA.ID); err != nil {
		t.Fatalf("root A first full reconciliation failed: %v", err)
	}
	a := f.services[f.rootA.ID]
	if a == nil || a.Gallery.Status().LastDone == 0 || a.Cinema.Status().LastDone == 0 {
		t.Fatal("root A did not finish both media scans")
	}
	if _, found := f.services[f.rootB.ID]; found {
		t.Fatal("root A reconciliation initialized unrelated root B")
	}
	// Offline volume is never silently replaced by a same-name directory.
	hidden := f.pathB + "-unplugged"
	if err := os.Rename(f.pathB, hidden); err != nil {
		t.Fatal(err)
	}
	if err := f.server.ReconcileRootMedia(ctx, f.rootB.ID); !errors.Is(err, roots.ErrOffline) {
		t.Fatalf("offline root attempted indexing: %v", err)
	}
	if _, found := f.services[f.rootB.ID]; found {
		t.Fatal("offline root instantiated media runtime")
	}
	// Restored original identity gets its first full catch-up reconciliation.
	if err := os.Rename(hidden, f.pathB); err != nil {
		t.Fatal(err)
	}
	if err := f.server.ReconcileRootMedia(ctx, f.rootB.ID); err != nil {
		t.Fatalf("root B recovery reconciliation failed: %v", err)
	}
	b := f.services[f.rootB.ID]
	if b == nil || b.Gallery.Status().LastDone == 0 || b.Cinema.Status().LastDone == 0 {
		t.Fatal("reconnected root did not finish both local libraries")
	}
}
