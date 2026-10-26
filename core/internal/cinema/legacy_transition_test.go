package cinema

import (
	"errors"
	"os"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestScanAndScrapeCannotStartDuringLegacyTransition(t *testing.T) {
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
	newRoot, err := os.MkdirTemp(home, ".lightisle-cinema-transition-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(newRoot)

	entered := make(chan struct{})
	resume := make(chan struct{})
	transition := make(chan error, 1)
	go func() {
		transition <- storage.SetRootWithLegacyTransition(newRoot, func() error {
			close(entered)
			<-resume
			return nil
		}, func() error { return nil })
	}()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		close(resume)
		t.Fatal("root transition did not acquire its gate")
	}
	if err := library.StartScan(); !errors.Is(err, ErrScanning) {
		close(resume)
		t.Fatalf("scan started during root transition: %v", err)
	}
	if err := library.StartScrape(false); !errors.Is(err, ErrScanning) {
		close(resume)
		t.Fatalf("scrape started during root transition: %v", err)
	}
	if library.Status().Running {
		close(resume)
		t.Fatal("blocked scan or scrape was marked running")
	}
	close(resume)
	select {
	case err := <-transition:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("root transition did not finish")
	}
}
