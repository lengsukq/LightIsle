package mediascope

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestWalkBatchesContinuesPastFormerLimit(t *testing.T) {
	const total = 200201
	count := 0
	scan := func(ctx context.Context, dir string, visit func([]files.Entry) error) error {
		if dir != "." {
			t.Fatalf("unexpected directory %q", dir)
		}
		for left := total; left > 0; {
			n := min(left, 200)
			batch := make([]files.Entry, n)
			for i := range batch {
				batch[i] = files.Entry{Type: "file", Name: "document.txt"}
			}
			if err := visit(batch); err != nil {
				return err
			}
			left -= n
		}
		return nil
	}
	err := WalkBatches(context.Background(), []string{"."}, func(string) bool { return false }, scan,
		func(batch []files.Entry) error {
			if len(batch) > 200 {
				t.Fatal("scan batch exceeded bound")
			}
			count += len(batch)
			return nil
		})
	if err != nil || count != total {
		t.Fatalf("walk stopped early: visited=%d err=%v", count, err)
	}
}

func TestWalkBatchesQueuesDirectoriesBeforeVisitorReusesBatch(t *testing.T) {
	const dirs = 1200
	visited := make(map[string]bool)
	scan := func(ctx context.Context, dir string, visit func([]files.Entry) error) error {
		visited[dir] = true
		if dir != "." {
			return nil
		}
		for offset := 0; offset < dirs; offset += 200 {
			batch := make([]files.Entry, 200)
			for i := range batch {
				batch[i] = files.Entry{Type: "folder", Path: fmt.Sprintf("folder-%d", offset+i)}
			}
			if err := visit(batch); err != nil {
				return err
			}
		}
		return nil
	}
	if err := WalkBatches(context.Background(), []string{"."}, func(s string) bool { return s == "folder-9" }, scan,
		func(batch []files.Entry) error {
			// The media indexer compacts the slice in place.
			for i := range batch {
				batch[i] = files.Entry{}
			}
			return nil
		}); err != nil {
		t.Fatal(err)
	}
	if len(visited) != dirs || visited["folder-9"] || !visited["folder-1199"] {
		t.Fatalf("directory queue incomplete: count=%d", len(visited))
	}
}

func TestWalkBatchesReturnsCancellationAndReadFailures(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	scan := func(ctx context.Context, dir string, visit func([]files.Entry) error) error {
		if err := visit([]files.Entry{{Name: "x", Type: "file"}}); err != nil {
			return err
		}
		return errors.New("directory_read_failed")
	}
	skip := func(string) bool { return false }
	if err := WalkBatches(ctx, []string{"."}, skip, scan, func([]files.Entry) error { return nil }); err == nil || err.Error() != "directory_read_failed" {
		t.Fatalf("read failure ignored: %v", err)
	}
	err := WalkBatches(ctx, []string{"."}, skip, scan, func([]files.Entry) error {
		cancel()
		return ctx.Err()
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation ignored: %v", err)
	}
}

func TestDirectoryQueueTruncationIsNotAnEmptyQueue(t *testing.T) {
	queue, err := newDirectoryQueue()
	if err != nil {
		t.Fatal(err)
	}
	defer queue.file.Close()
	if err := queue.push("folder"); err != nil {
		t.Fatal(err)
	}
	if err := queue.file.Truncate(0); err != nil {
		t.Fatal(err)
	}
	if _, err := queue.pop(); err == nil || errors.Is(err, errQueueEmpty) {
		t.Fatalf("damaged queue was treated as complete: %v", err)
	}
}
