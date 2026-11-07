package files

import (
	"context"
	"crypto/sha256"
	"errors"
	"os"
	"path"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A restore can temporarily move the original out of the trash and then have
// to roll that move back. Purge must not forget its journal in that interval.
func TestPurgeWaitsForRestoreAndItsRollback(t *testing.T) {
	for _, failSync := range []bool{false, true} {
		for _, separateStore := range []bool{false, true} {
			name := "restore_succeeds"
			if failSync {
				name = "restore_rolls_back"
			}
			if separateStore {
				name += "_separate_store"
			}
			t.Run(name, func(t *testing.T) {
				root := t.TempDir()
				s, err := Open(root)
				if err != nil {
					t.Fatal(err)
				}
				defer s.Close()
				purger := s
				if separateStore {
					purger, err = Open(root)
					if err != nil {
						t.Fatal(err)
					}
					defer purger.Close()
				}
				if _, err := s.Upload("original.txt", strings.NewReader("original")); err != nil {
					t.Fatal(err)
				}
				if err := s.MoveToTrash("original.txt"); err != nil {
					t.Fatal(err)
				}
				items, err := s.TrashList()
				if err != nil || len(items) != 1 {
					t.Fatalf("trash: %+v %v", items, err)
				}
				id := items[0].ID
				entered, release := make(chan struct{}), make(chan struct{})
				calls := 0
				s.syncDir = func(f *os.File) error {
					calls++
					if calls == 1 {
						close(entered)
						<-release
						if failSync {
							return errors.New("injected restore sync failure")
						}
					}
					return f.Sync()
				}
				restoreDone := make(chan error, 1)
				go func() { restoreDone <- s.Restore(id) }()
				<-entered
				purgeStarted, purgeDone := make(chan struct{}), make(chan error, 1)
				go func() { close(purgeStarted); purgeDone <- purger.Purge(id) }()
				<-purgeStarted
				select {
				case err := <-purgeDone:
					close(release)
					<-restoreDone
					t.Fatalf("purge ran before restore finished: %v", err)
				case <-time.After(75 * time.Millisecond):
				}
				close(release)
				restoreErr, purgeErr := <-restoreDone, <-purgeDone
				if failSync {
					if !errors.Is(restoreErr, ErrStorageSync) || purgeErr != nil {
						t.Fatalf("rollback/purge: %v / %v", restoreErr, purgeErr)
					}
					if _, err := s.root.Lstat(path.Join(Trash, id)); !errors.Is(err, os.ErrNotExist) {
						t.Fatalf("purged item remains: %v", err)
					}
				} else {
					if restoreErr != nil || !errors.Is(purgeErr, os.ErrNotExist) {
						t.Fatalf("restore/purge: %v / %v", restoreErr, purgeErr)
					}
					data, err := s.root.ReadFile("original.txt")
					if err != nil || string(data) != "original" {
						t.Fatalf("restored original: %q %v", data, err)
					}
				}
				if _, err := s.root.Lstat(path.Join(Trash, id+".json")); !errors.Is(err, os.ErrNotExist) {
					t.Fatalf("unexpected leftover journal: %v", err)
				}
			})
		}
	}
}

func TestPurgeWaitsForCrossDiskSourceVerification(t *testing.T) {
	root := t.TempDir()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	purger, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer purger.Close()
	const original = "family-original"
	if _, err := s.Upload("family.jpg", strings.NewReader(original)); err != nil {
		t.Fatal(err)
	}
	info, err := s.root.Stat("family.jpg")
	if err != nil {
		t.Fatal(err)
	}
	destination := t.TempDir()
	published := filepath.Join(destination, "family.jpg")
	if err := os.WriteFile(published, []byte(original), 0600); err != nil {
		t.Fatal(err)
	}
	entered, release := make(chan string, 1), make(chan struct{})
	s.rename = func(from, to string) error {
		err := s.root.Rename(from, to)
		if err == nil && from == "family.jpg" {
			entered <- path.Base(to)
			<-release
		}
		return err
	}
	type result struct {
		value verifiedTrashResult
		err   error
	}
	moved := make(chan result, 1)
	go func() {
		value, err := s.moveToTrashVerified(context.Background(), "family.jpg", info, published, destination, sha256.Sum256([]byte(original)))
		moved <- result{value, err}
	}()
	id := <-entered
	purgeStarted, purgeDone := make(chan struct{}), make(chan error, 1)
	go func() { close(purgeStarted); purgeDone <- purger.Purge(id) }()
	<-purgeStarted
	select {
	case err := <-purgeDone:
		close(release)
		<-moved
		t.Fatalf("purge ran before cross-disk verification: %v", err)
	case <-time.After(75 * time.Millisecond):
	}
	close(release)
	transfer, purgeErr := <-moved, <-purgeDone
	if transfer.err != nil || !transfer.value.InTrash || purgeErr != nil {
		t.Fatalf("verified move/purge: %+v %v / %v", transfer.value, transfer.err, purgeErr)
	}
	if data, err := os.ReadFile(published); err != nil || string(data) != original {
		t.Fatalf("verified destination changed: %q %v", data, err)
	}
}
