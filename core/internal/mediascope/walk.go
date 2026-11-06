package mediascope

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"os"

	"github.com/lengsukq/lightisle/core/internal/files"
)

// directoryQueue is an unlinked private scratch file rather than an in-memory
// list. A root with millions of child directories therefore does not require
// millions of path strings in the server heap. The file is only a work queue;
// it is discarded on cancellation, error, or process exit and is never used
// as evidence that a scan completed.
type directoryQueue struct {
	file       *os.File
	read, tail int64
}

var errQueueEmpty = errors.New("scan_queue_empty")

func newDirectoryQueue() (*directoryQueue, error) {
	f, err := os.CreateTemp("", "lightisle-media-scan-*")
	if err != nil {
		return nil, err
	}
	if err := os.Remove(f.Name()); err != nil {
		f.Close()
		return nil, err
	}
	return &directoryQueue{file: f}, nil
}

func (q *directoryQueue) push(name string) error {
	if len(name) == 0 || len(name) > 1<<20 {
		return errors.New("scan_directory_path_invalid")
	}
	buf := make([]byte, 4+len(name))
	binary.BigEndian.PutUint32(buf, uint32(len(name)))
	copy(buf[4:], name)
	n, err := q.file.WriteAt(buf, q.tail)
	if err != nil {
		return err
	}
	if n != len(buf) {
		return io.ErrShortWrite
	}
	q.tail += int64(n)
	return nil
}

func (q *directoryQueue) pop() (string, error) {
	if q.read == q.tail {
		return "", errQueueEmpty
	}
	var header [4]byte
	if _, err := q.file.ReadAt(header[:], q.read); err != nil {
		return "", err
	}
	n := int64(binary.BigEndian.Uint32(header[:]))
	if n == 0 || n > 1<<20 || q.tail-q.read-4 < n {
		return "", errors.New("scan_queue_invalid")
	}
	buf := make([]byte, int(n))
	if _, err := q.file.ReadAt(buf, q.read+4); err != nil {
		return "", err
	}
	q.read += 4 + n
	return string(buf), nil
}

// WalkBatches continues through all directories and bounded entry batches.
// Any cancellation, directory read failure, or scratch-file failure is
// returned to the caller; only a nil result permits reconciliation of unseen
// index rows. Cancellation/error can be retried from the original scope.
func WalkBatches(ctx context.Context, roots []string, skip func(string) bool,
	scan func(context.Context, string, func([]files.Entry) error) error,
	visit func([]files.Entry) error,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	queue, err := newDirectoryQueue()
	if err != nil {
		return err
	}
	defer queue.file.Close()
	for _, dir := range roots {
		if err := queue.push(dir); err != nil {
			return err
		}
	}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		dir, err := queue.pop()
		if errors.Is(err, errQueueEmpty) {
			return ctx.Err()
		}
		if err != nil {
			return err
		}
		if skip(dir) {
			continue
		}
		if err := scan(ctx, dir, func(entries []files.Entry) error {
			if err := ctx.Err(); err != nil {
				return err
			}
			for _, entry := range entries {
				if entry.Type == "folder" && !skip(entry.Path) {
					if err := queue.push(entry.Path); err != nil {
						return err
					}
				}
			}
			return visit(entries)
		}); err != nil {
			return err
		}
	}
}
