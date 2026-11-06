package gallery

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

func batchTestLibrary(t *testing.T, names ...string) (*Library, string, []files.Entry) {
	t.Helper()
	root := t.TempDir()
	handle, err := os.OpenRoot(root)
	if err != nil {
		t.Fatal(err)
	}
	defer handle.Close()
	store, err := files.NewPinnedManager(handle)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	lib, err := Open(t.TempDir(), store)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { lib.Close() })
	var entries []files.Entry
	for _, name := range names {
		p := filepath.Join(root, name)
		if err := os.WriteFile(p, []byte("synthetic"), 0600); err != nil {
			t.Fatal(err)
		}
		info, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		entries = append(entries, files.Entry{Name: name, Path: name, Type: "file", Size: info.Size(), Modified: info.ModTime(), Identity: files.MediaFileIdentity(info), SingleLink: files.MediaFileHasSingleLink(info)})
	}
	return lib, root, entries
}

func TestScanBatchKeepsFreshCaptureAndUserMetadata(t *testing.T) {
	lib, root, entries := batchTestLibrary(t, "one.jpg", "two.jpg")
	if err := lib.indexScanBatch(context.Background(), root, root, 1, entries); err != nil {
		t.Fatal(err)
	}
	if _, err := lib.db.Exec(`UPDATE assets SET taken_at=123,camera_model='camera',exif_json='{"iso":400}',favorite=1;
		CREATE TRIGGER no_metadata_rewrite BEFORE UPDATE OF taken_at,camera_model,exif_json,size,modified ON assets
		BEGIN SELECT RAISE(ABORT,'fresh_metadata_rewritten'); END`); err != nil {
		t.Fatal(err)
	}
	if err := lib.indexScanBatch(context.Background(), root, root, 2, entries); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := lib.db.QueryRow(`SELECT COUNT(*) FROM assets WHERE seen=2 AND taken_at=123 AND camera_model='camera'
		AND exif_json='{"iso":400}' AND favorite=1`).Scan(&count); err != nil || count != 2 {
		t.Fatalf("preserved=%d: %v", count, err)
	}
}

func TestScanBatchRollsBackWritesOnErrorAndCancellation(t *testing.T) {
	lib, root, entries := batchTestLibrary(t, "one.jpg", "two.jpg")
	if _, err := lib.db.Exec(`CREATE TRIGGER fail_second BEFORE INSERT ON assets WHEN NEW.path='two.jpg'
		BEGIN SELECT RAISE(ABORT,'simulated_write_failure'); END`); err != nil {
		t.Fatal(err)
	}
	if err := lib.indexScanBatch(context.Background(), root, root, 1, entries); err == nil {
		t.Fatal("write failure ignored")
	}
	var count int
	if err := lib.db.QueryRow("SELECT COUNT(*) FROM assets").Scan(&count); err != nil || count != 0 {
		t.Fatalf("partial batch committed: %d %v", count, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := lib.indexScanBatch(ctx, root, root, 2, entries); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation: %v", err)
	}
	if err := lib.indexScanBatch(context.Background(), root, root+"-replaced", 3, entries); err == nil {
		t.Fatal("changed share accepted")
	}
}

func TestScanBatchProbeDoesNotBlockReadersAndCancellationDoesNotPublish(t *testing.T) {
	lib, root, entries := batchTestLibrary(t, "one.heic")
	entered := make(chan struct{})
	worker := &fakeMediaWorker{probe: func(ctx context.Context, _ *os.File, _ string) (mediaworker.Metadata, error) {
		close(entered)
		<-ctx.Done()
		return mediaworker.Metadata{}, ctx.Err()
	}}
	lib.SetMediaWorker(worker)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- lib.indexScanBatch(ctx, root, root, 1, entries) }()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("probe not reached")
	}
	readCtx, readCancel := context.WithTimeout(context.Background(), time.Second)
	defer readCancel()
	var count int
	if err := lib.db.QueryRowContext(readCtx, "SELECT COUNT(*) FROM assets").Scan(&count); err != nil || count != 0 {
		cancel()
		<-done
		t.Fatalf("reader blocked: %d %v", count, err)
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled batch: %v", err)
	}
	if err := lib.db.QueryRow("SELECT COUNT(*) FROM assets").Scan(&count); err != nil || count != 0 {
		t.Fatalf("cancelled batch published: %d %v", count, err)
	}
}
