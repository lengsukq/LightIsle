package gallery

import (
	"errors"
	"os"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestScanAndBackfillCannotStartDuringLegacyTransition(t *testing.T) {
	data := t.TempDir()
	storage, err := files.NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	library, err := Open(data, storage)
	if err != nil {
		t.Fatal(err)
	}
	defer library.Close()

	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	newRoot, err := os.MkdirTemp(home, ".lightisle-gallery-transition-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(newRoot)
	deadline := time.Now().Add(10 * time.Second)
	gateReady := false
	for time.Now().Before(deadline) {
		release, ok := storage.TryAcquireLegacyRequest()
		if ok {
			release()
			gateReady = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !gateReady {
		t.Fatal("gallery backfill did not release the legacy request gate")
	}

	entered := make(chan struct{})
	resume := make(chan struct{})
	deadline = time.Now().Add(10 * time.Second)
	acquired := false
	var transition chan error
	for time.Now().Before(deadline) {
		transition = make(chan error, 1)
		go func(done chan<- error) {
			done <- storage.SetRootWithLegacyTransition(newRoot, func() error {
				close(entered)
				<-resume
				return nil
			}, func() error { return nil })
		}(transition)
		select {
		case <-entered:
			acquired = true
		case err := <-transition:
			if !errors.Is(err, files.ErrLegacyTransitionBusy) {
				t.Fatalf("transition failed before protected callback: %v", err)
			}
			time.Sleep(10 * time.Millisecond)
		case <-time.After(time.Until(deadline)):
			close(resume)
			t.Fatal("root transition did not acquire its gate")
		}
		if acquired {
			break
		}
	}
	if !acquired {
		close(resume)
		t.Fatal("root transition did not acquire its gate")
	}
	if err := library.StartScan(); !errors.Is(err, ErrBusy) {
		close(resume)
		t.Fatalf("scan started during root transition: %v", err)
	}
	if processed, retry := library.backfillTick(); processed != 0 || !retry {
		close(resume)
		t.Fatalf("backfill ran during root transition: processed=%d retry=%v", processed, retry)
	}
	if library.Status().Running {
		close(resume)
		t.Fatal("blocked scan was marked running")
	}
	close(resume)
	select {
	case err := <-transition:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("root transition did not finish")
	}
}
