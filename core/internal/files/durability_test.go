package files

import (
	"errors"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"testing"
)

func TestUploadSyncsBeforePublishingAndNeverReportsSyncFailureAsSuccess(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	var fileSyncs, directorySyncs int
	s.syncFile = func(f *os.File) error {
		fileSyncs++
		return f.Sync()
	}
	s.syncDir = func(f *os.File) error {
		directorySyncs++
		return f.Sync()
	}
	if n, err := s.Upload("ok.txt", strings.NewReader("durable")); err != nil || n != 7 {
		t.Fatalf("upload = %d, %v", n, err)
	}
	if fileSyncs != 1 || directorySyncs != 3 {
		t.Fatalf("sync calls file=%d dir=%d", fileSyncs, directorySyncs)
	}

	s.syncFile = func(*os.File) error { return errors.New("file sync failed") }
	if _, err := s.Upload("file-sync-error.txt", strings.NewReader("not published")); err == nil {
		t.Fatal("file sync error was ignored")
	}
	if _, err := s.root.Lstat("file-sync-error.txt"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("file published after sync failure: %v", err)
	}

	s.syncFile = func(f *os.File) error { return f.Sync() }
	directorySyncs = 0
	s.syncDir = func(f *os.File) error {
		directorySyncs++
		if directorySyncs == 2 {
			return errors.New("directory sync failed")
		}
		return f.Sync()
	}
	if _, err := s.Upload("dir-sync-error.txt", strings.NewReader("published, not acknowledged")); !errors.Is(err, ErrPublishedSync) {
		t.Fatalf("directory sync error = %v", err)
	}
	if _, _, err := s.Read("dir-sync-error.txt"); err != nil {
		t.Fatalf("destination should remain visible after post-publication sync failure: %v", err)
	}
	entries, err := s.root.Open(".")
	if err != nil {
		t.Fatal(err)
	}
	names, err := entries.ReadDir(-1)
	entries.Close()
	if err != nil {
		t.Fatal(err)
	}
	stagingFound := false
	for _, entry := range names {
		if strings.HasPrefix(entry.Name(), ".lightisle-upload-") {
			stagingFound = true
			break
		}
	}
	if !stagingFound {
		t.Fatal("staging link was discarded after uncertain publication")
	}
}

func TestPagePropagatesNonDisappearanceStatErrors(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.Upload("entry.txt", strings.NewReader("x")); err != nil {
		t.Fatal(err)
	}
	want := errors.New("simulated metadata I/O error")
	s.statEntry = func(_ *os.File, _ string) (os.FileInfo, error) { return nil, want }
	if _, _, err := s.Page(".", "", 10); !errors.Is(err, want) {
		t.Fatalf("Page error = %v, want %v", err, want)
	}
}

// recordSyncs installs an injected directory sync that records which share
// directory was flushed. The returned slice lets a test assert ordering;
// failAt > 0 makes that call fail.
func recordSyncs(t *testing.T, s *Store, failAt int) *[]string {
	t.Helper()
	var synced []string
	calls := 0
	s.syncDir = func(f *os.File) error {
		calls++
		synced = append(synced, syncLabel(t, s, f))
		if calls == failAt {
			return errors.New("injected directory sync failure")
		}
		return f.Sync()
	}
	return &synced
}

// syncLabel maps a synced descriptor back to a share-relative name so tests
// can assert ordering without depending on *os.File.Name().
func syncLabel(t *testing.T, s *Store, f *os.File) string {
	t.Helper()
	info, err := f.Stat()
	if err != nil {
		t.Fatal(err)
	}
	root := s.root.Name()
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	relatives := []string{"."}
	for _, entry := range entries {
		if entry.IsDir() {
			relatives = append(relatives, entry.Name())
		}
	}
	for _, relative := range relatives {
		candidate, err := os.Stat(filepath.Join(root, relative))
		if err == nil && os.SameFile(info, candidate) {
			return relative
		}
	}
	return "?" + filepath.Base(f.Name())
}

func TestMoveSyncsDestinationBeforeSource(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, dir := range []string{"from", "to"} {
		if err := s.Mkdir(dir); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.Upload("from/item.txt", strings.NewReader("move me")); err != nil {
		t.Fatal(err)
	}

	synced := recordSyncs(t, s, 0)
	if err := s.Move("from/item.txt", "to/item.txt"); err != nil {
		t.Fatal(err)
	}
	// The destination directory must be durable before the source removal is
	// acknowledged, so a crash cannot drop the only surviving copy.
	if got := *synced; len(got) != 2 || got[0] != "to" || got[1] != "from" {
		t.Fatalf("directory sync order = %v, want [to from]", got)
	}

	if _, err := s.Upload("to/second.txt", strings.NewReader("second")); err != nil {
		t.Fatal(err)
	}
	synced = recordSyncs(t, s, 1)
	if err := s.Move("to/second.txt", "from/second.txt"); !errors.Is(err, ErrStorageSync) {
		t.Fatalf("move reported success without a durable directory entry: %v", err)
	}
	if _, _, err := s.Read("from/second.txt"); err != nil {
		t.Fatalf("move did not happen before the failed barrier: %v", err)
	}
}

func TestMkdirSyncsParentAndFailsLoudly(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	synced := recordSyncs(t, s, 0)
	if err := s.Mkdir("new-folder"); err != nil {
		t.Fatal(err)
	}
	if got := *synced; len(got) != 1 {
		t.Fatalf("mkdir directory syncs = %v, want exactly one parent sync", got)
	}
	synced = recordSyncs(t, s, 1)
	if err := s.Mkdir("unacknowledged"); !errors.Is(err, ErrStorageSync) {
		t.Fatalf("mkdir reported success without a durable parent entry: %v", err)
	}
}

func TestCopySyncsStagedDataAndDirectoriesBeforePublishing(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Mkdir("album"); err != nil {
		t.Fatal(err)
	}
	if err := s.Mkdir("album/nested"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Upload("album/one.txt", strings.NewReader("one")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Upload("album/nested/two.txt", strings.NewReader("two")); err != nil {
		t.Fatal(err)
	}

	fileSyncs := 0
	s.syncFile = func(f *os.File) error {
		fileSyncs++
		return f.Sync()
	}
	synced := recordSyncs(t, s, 0)
	if err := s.Copy("album", "copy"); err != nil {
		t.Fatal(err)
	}
	if fileSyncs != 2 {
		t.Fatalf("staged file syncs = %d, want one per copied file", fileSyncs)
	}
	got := *synced
	if len(got) < 3 {
		t.Fatalf("copy directory syncs = %v, want nested, staged root and destination", got)
	}
	if got[len(got)-1] != "." {
		t.Fatalf("copy synced %q last; the published destination must be synced last", got[len(got)-1])
	}

	// A failure inside the staged tree must not publish anything.
	s.syncFile = func(f *os.File) error { return f.Sync() }
	recordSyncs(t, s, 1)
	if err := s.Copy("album", "never-published"); !errors.Is(err, ErrStorageSync) {
		t.Fatalf("directory copy succeeded without durable staging: %v", err)
	}
	if _, err := s.root.Lstat("never-published"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("partially synced copy was published: %v", err)
	}

	if _, err := s.Upload("file.txt", strings.NewReader("file copy")); err != nil {
		t.Fatal(err)
	}
	fileSyncs = 0
	s.syncFile = func(f *os.File) error {
		fileSyncs++
		return f.Sync()
	}
	recordSyncs(t, s, 0)
	if err := s.Copy("file.txt", "file-copy.txt"); err != nil {
		t.Fatal(err)
	}
	if fileSyncs != 1 {
		t.Fatalf("file copy syncs = %d, want the staged data flushed with F_FULLFSYNC before publication", fileSyncs)
	}
	recordSyncs(t, s, 1)
	if err := s.Copy("file.txt", "file-copy-2.txt"); !errors.Is(err, ErrStorageSync) {
		t.Fatalf("file copy reported success without a durable destination: %v", err)
	}
}

func TestMoveToTrashJournalsBeforeMovingAndRollsBack(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Mkdir("docs"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Upload("docs/report.txt", strings.NewReader("report")); err != nil {
		t.Fatal(err)
	}

	journalVisible := false
	s.rename = func(from, to string) error {
		if from == "docs/report.txt" {
			entries, readErr := os.ReadDir(filepath.Join(s.root.Name(), Trash))
			if readErr != nil {
				return readErr
			}
			for _, entry := range entries {
				if strings.HasSuffix(entry.Name(), ".json") {
					journalVisible = true
				}
			}
		}
		return s.root.Rename(from, to)
	}
	synced := recordSyncs(t, s, 0)
	if err := s.MoveToTrash("docs/report.txt"); err != nil {
		t.Fatal(err)
	}
	if !journalVisible {
		t.Fatal("trash journal was not durable before the item was moved")
	}
	// Journal publication, then trash, then the source directory.
	got := *synced
	if len(got) != 3 || got[0] != Trash || got[1] != Trash || got[2] != "docs" {
		t.Fatalf("trash directory sync order = %v, want [trash trash docs]", got)
	}

	// A failed post-move barrier must restore the item and forget the journal.
	if _, err := s.Upload("docs/other.txt", strings.NewReader("other")); err != nil {
		t.Fatal(err)
	}
	s.rename = nil
	recordSyncs(t, s, 2)
	if err := s.MoveToTrash("docs/other.txt"); !errors.Is(err, ErrStorageSync) {
		t.Fatalf("trash reported success without durable directories: %v", err)
	}
	if _, _, err := s.Read("docs/other.txt"); err != nil {
		t.Fatalf("item was not restored after the failed barrier: %v", err)
	}
	entries, err := s.TrashList()
	if err != nil || len(entries) != 1 {
		t.Fatalf("rollback left a phantom trash entry: %#v %v", entries, err)
	}
}

func TestMoveToTrashJournalFailureLeavesItemInPlace(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.Upload("keep.txt", strings.NewReader("keep")); err != nil {
		t.Fatal(err)
	}
	s.syncFile = func(*os.File) error { return errors.New("injected file sync failure") }
	if err := s.MoveToTrash("keep.txt"); !errors.Is(err, ErrStorageSync) {
		t.Fatalf("trash succeeded without a durable journal: %v", err)
	}
	if _, _, err := s.Read("keep.txt"); err != nil {
		t.Fatalf("item moved without a journal: %v", err)
	}

	// A journal that cannot be made durable must also abort before the move.
	s.syncFile = func(f *os.File) error { return f.Sync() }
	recordSyncs(t, s, 1)
	if err := s.MoveToTrash("keep.txt"); !errors.Is(err, ErrStorageSync) {
		t.Fatalf("trash succeeded with a non-durable journal: %v", err)
	}
	if _, _, err := s.Read("keep.txt"); err != nil {
		t.Fatalf("item moved with a non-durable journal: %v", err)
	}
	dir, err := os.ReadDir(filepath.Join(s.root.Name(), Trash))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range dir {
		if strings.HasSuffix(entry.Name(), ".json") || strings.HasPrefix(entry.Name(), ".lightisle-") {
			t.Fatalf("failed trash left metadata behind: %s", entry.Name())
		}
	}
}

func TestMoveToTrashRollbackNeverOverwritesRecreatedOriginal(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.Upload("racy.txt", strings.NewReader("original")); err != nil {
		t.Fatal(err)
	}
	calls := 0
	s.syncDir = func(f *os.File) error {
		calls++
		if calls == 2 {
			// Another process recreates the original name between the move and
			// our failed durability barrier.
			if err := os.WriteFile(filepath.Join(s.root.Name(), "racy.txt"), []byte("newer"), 0600); err != nil {
				return err
			}
			return errors.New("injected directory sync failure")
		}
		return f.Sync()
	}
	if err := s.MoveToTrash("racy.txt"); !errors.Is(err, ErrStorageSync) {
		t.Fatalf("trash reported success without durable directories: %v", err)
	}
	f, _, err := s.Read("racy.txt")
	if err != nil {
		t.Fatal(err)
	}
	data, err := io.ReadAll(f)
	f.Close()
	if err != nil || string(data) != "newer" {
		t.Fatalf("rollback clobbered the recreated file: %q %v", data, err)
	}
	// The original bytes must still be tracked by a journal, not orphaned.
	items, err := s.TrashList()
	if err != nil || len(items) != 1 || items[0].OriginalPath != "racy.txt" {
		t.Fatalf("unrecovered trash state: %#v %v", items, err)
	}
	trashed, err := s.root.ReadFile(path.Join(Trash, items[0].ID))
	if err != nil || string(trashed) != "original" {
		t.Fatalf("trashed content = %q, err=%v", trashed, err)
	}
}

func TestPurgeRemovesContentBeforeForgettingJournal(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.Upload("gone.txt", strings.NewReader("gone")); err != nil {
		t.Fatal(err)
	}
	if err := s.MoveToTrash("gone.txt"); err != nil {
		t.Fatal(err)
	}
	items, err := s.TrashList()
	if err != nil || len(items) != 1 {
		t.Fatalf("trash list: %#v %v", items, err)
	}
	id := items[0].ID

	journalRemovalSawSyncedTrash := false
	removals := 0
	synced := recordSyncs(t, s, 0)
	s.remove = func(name string) error {
		removals++
		if name == path.Join(Trash, id+".json") {
			if _, err := s.root.Lstat(path.Join(Trash, id)); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("journal removed while trash content still exists: %v", err)
			}
			if len(*synced) != 1 || (*synced)[0] != Trash {
				t.Fatalf("journal removed before the content removal was durable: %v", *synced)
			}
			journalRemovalSawSyncedTrash = true
		}
		return s.root.Remove(name)
	}
	if err := s.Purge(id); err != nil {
		t.Fatal(err)
	}
	if !journalRemovalSawSyncedTrash {
		t.Fatal("purge never verified journal ordering")
	}
	if _, err := s.root.Lstat(path.Join(Trash, id)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("purged content remains: %v", err)
	}
	if _, err := s.root.Lstat(path.Join(Trash, id+".json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("purged journal remains: %v", err)
	}
	if removals < 1 {
		t.Fatal("purge did not remove anything")
	}

	// Failing the content-removal barrier must keep the journal, so the trash
	// never holds content that no metadata describes.
	if _, err := s.Upload("kept.txt", strings.NewReader("kept")); err != nil {
		t.Fatal(err)
	}
	if err := s.MoveToTrash("kept.txt"); err != nil {
		t.Fatal(err)
	}
	items, err = s.TrashList()
	if err != nil || len(items) != 1 {
		t.Fatalf("trash list: %#v %v", items, err)
	}
	s.remove = nil
	recordSyncs(t, s, 1)
	if err := s.Purge(items[0].ID); !errors.Is(err, ErrStorageSync) {
		t.Fatalf("purge reported success without a durable removal: %v", err)
	}
}

func TestRestoreSyncsBeforeForgettingJournal(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Mkdir("docs"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Upload("docs/report.txt", strings.NewReader("report")); err != nil {
		t.Fatal(err)
	}
	if err := s.MoveToTrash("docs/report.txt"); err != nil {
		t.Fatal(err)
	}
	items, err := s.TrashList()
	if err != nil || len(items) != 1 {
		t.Fatalf("trash list: %#v %v", items, err)
	}
	id := items[0].ID

	journalRemovalSawRestoredContent := false
	s.remove = func(name string) error {
		if name == path.Join(Trash, id+".json") {
			if _, err := s.root.Lstat("docs/report.txt"); err != nil {
				t.Fatalf("journal removed before restored content is in place: %v", err)
			}
			journalRemovalSawRestoredContent = true
		}
		return s.root.Remove(name)
	}
	synced := recordSyncs(t, s, 0)
	if err := s.Restore(id); err != nil {
		t.Fatal(err)
	}
	if !journalRemovalSawRestoredContent {
		t.Fatal("restore never verified journal ordering")
	}
	// Destination first, then the trash directory.
	got := *synced
	if len(got) < 2 || got[0] != "docs" || got[1] != Trash {
		t.Fatalf("restore directory sync order = %v, want [docs trash ...]", got)
	}

	// A failed restore barrier must put the item back in the trash with its
	// journal intact rather than losing it between the two names.
	if _, err := s.Upload("docs/second.txt", strings.NewReader("second")); err != nil {
		t.Fatal(err)
	}
	if err := s.MoveToTrash("docs/second.txt"); err != nil {
		t.Fatal(err)
	}
	items, err = s.TrashList()
	if err != nil || len(items) != 1 {
		t.Fatalf("trash list: %#v %v", items, err)
	}
	s.remove = nil
	recordSyncs(t, s, 1)
	if err := s.Restore(items[0].ID); !errors.Is(err, ErrStorageSync) {
		t.Fatalf("restore reported success without a durable move: %v", err)
	}
	if _, _, err := s.Read("docs/second.txt"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("restore was not rolled back: %v", err)
	}
	if _, err := s.root.Lstat(path.Join(Trash, items[0].ID)); err != nil {
		t.Fatalf("rolled-back restore lost its content: %v", err)
	}
	if _, err := s.root.Lstat(path.Join(Trash, items[0].ID+".json")); err != nil {
		t.Fatalf("rolled-back restore lost its journal: %v", err)
	}
}

func TestTrashDirectoryCreationIsDurable(t *testing.T) {
	root := t.TempDir()
	r, err := os.OpenRoot(root)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	s := &Store{root: r}
	synced := 0
	s.syncDir = func(f *os.File) error {
		synced++
		return f.Sync()
	}
	if err := s.ensureTrashDirectory(); err != nil {
		t.Fatal(err)
	}
	if synced != 1 {
		t.Fatalf("trash creation directory syncs = %d, want 1", synced)
	}
	info, err := r.Lstat(Trash)
	if err != nil || !info.IsDir() {
		t.Fatalf("trash directory missing: %v %v", info, err)
	}
	// Re-opening an existing share must not re-sync anything.
	synced = 0
	if err := s.ensureTrashDirectory(); err != nil {
		t.Fatal(err)
	}
	if synced != 0 {
		t.Fatalf("existing trash directory synced %d times", synced)
	}
}
