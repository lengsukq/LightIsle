package files

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func newScanManager(t testing.TB, count int) (*Manager, string) {
	t.Helper()
	m, err := NewManager(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = m.Close() })
	root, online := m.State()
	if !online {
		t.Fatal("new root offline")
	}
	for i := 0; i < count; i++ {
		if err := os.WriteFile(filepath.Join(root, fmt.Sprintf("file-%05d.txt", i)), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	return m, root
}

func TestScanDirectoryBatchesAndAllowsNestedReads(t *testing.T) {
	m, root := newScanManager(t, 601)
	if err := os.WriteFile(filepath.Join(root, ".lightisle-private"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), "private.txt")
	if err := os.WriteFile(outside, []byte("private"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "symlink.txt")); err != nil {
		t.Fatal(err)
	}
	seen := make(map[string]bool)
	err := m.ScanDirectory(context.Background(), ".", func(entries []Entry) error {
		if len(entries) > scanDirectoryBatch {
			t.Fatalf("unbounded batch: %d", len(entries))
		}
		for _, entry := range entries {
			if seen[entry.Path] || entry.Path != entry.Name || entry.Type != "file" {
				t.Fatalf("unexpected entry: %+v", entry)
			}
			seen[entry.Path] = true
			f, _, err := m.Read(entry.Path)
			if err != nil {
				return err
			}
			_ = f.Close()
		}
		return nil
	})
	if err != nil || len(seen) != 601 || seen["symlink.txt"] || seen[".lightisle-private"] {
		t.Fatalf("scan: entries=%d error=%v", len(seen), err)
	}
}

func TestScanDirectoryStopsOnCancellationAndCallbackFailure(t *testing.T) {
	m, _ := newScanManager(t, 401)
	for _, cancel := range []bool{false, true} {
		ctx, stop := context.WithCancel(context.Background())
		calls := 0
		failed := errors.New("probe failed")
		err := m.ScanDirectory(ctx, ".", func([]Entry) error {
			calls++
			if cancel {
				stop()
				return nil
			}
			return failed
		})
		stop()
		want := failed
		if cancel {
			want = context.Canceled
		}
		if !errors.Is(err, want) || calls != 1 {
			t.Fatalf("cancel=%v calls=%d error=%v", cancel, calls, err)
		}
	}
}

func TestScanDirectoryRejectsReplacementAndOfflineRoot(t *testing.T) {
	for _, replaceRoot := range []bool{false, true} {
		t.Run(fmt.Sprint(replaceRoot), func(t *testing.T) {
			m, root := newScanManager(t, 0)
			dir := filepath.Join(root, "photos")
			if err := os.Mkdir(dir, 0700); err != nil {
				t.Fatal(err)
			}
			for i := 0; i < 401; i++ {
				if err := os.WriteFile(filepath.Join(dir, fmt.Sprint(i)), nil, 0600); err != nil {
					t.Fatal(err)
				}
			}
			calls := 0
			err := m.ScanDirectory(context.Background(), "photos", func([]Entry) error {
				calls++
				target := dir
				if replaceRoot {
					target = root
				}
				if err := os.Rename(target, target+"-original"); err != nil {
					return err
				}
				return os.Mkdir(target, 0700)
			})
			if err == nil || calls != 1 {
				t.Fatalf("changed directory accepted: calls=%d err=%v", calls, err)
			}
		})
	}
}

func BenchmarkDirectoryReconciliation(b *testing.B) {
	for _, count := range []int{2_000, 10_000} {
		m, _ := newScanManager(b, count)
		for _, method := range []string{"paged", "streamed"} {
			b.Run(fmt.Sprintf("%d/%s", count, method), func(b *testing.B) {
				b.ReportAllocs()
				for i := 0; i < b.N; i++ {
					visited := 0
					var err error
					if method == "streamed" {
						err = m.ScanDirectory(context.Background(), ".", func(entries []Entry) error {
							visited += len(entries)
							return nil
						})
					} else {
						cursor := ""
						for {
							var entries []Entry
							entries, cursor, err = m.Page(".", cursor, 200)
							visited += len(entries)
							if err != nil || cursor == "" {
								break
							}
						}
					}
					if err != nil || visited != count {
						b.Fatalf("visited=%d error=%v", visited, err)
					}
				}
			})
		}
	}
}

func TestScanDirectoryReportsReadFailure(t *testing.T) {
	m, _ := newScanManager(t, 3)
	m.store.statEntry = func(*os.File, string) (os.FileInfo, error) { return nil, io.ErrUnexpectedEOF }
	if err := m.ScanDirectory(context.Background(), ".", func([]Entry) error {
		t.Fatal("incomplete batch delivered after stat failure")
		return nil
	}); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("read failure was swallowed: %v", err)
	}
}
