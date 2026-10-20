package files

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"golang.org/x/sys/unix"
)

func openPageTestStore(t *testing.T) (*Store, string) {
	t.Helper()
	root := t.TempDir()
	store, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	return store, root
}

// An unreadable regular file must still be listable: enumeration only needs
// search permission on the directory, never read access to the file itself.
func TestPageListsUnreadableRegularFiles(t *testing.T) {
	store, root := openPageTestStore(t)
	path := filepath.Join(root, "locked.bin")
	if err := os.WriteFile(path, []byte("secret"), 0000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0600) })

	entries, next, err := store.Page(".", "", 10)
	if err != nil {
		t.Fatalf("unreadable file broke pagination: %v", err)
	}
	if next != "" {
		t.Fatalf("unexpected next cursor %q", next)
	}
	if len(entries) != 1 || entries[0].Name != "locked.bin" || entries[0].Type != "file" || entries[0].Size != 6 {
		t.Fatalf("unreadable file missing from page: %+v", entries)
	}
}

func TestStatEntryNoFollowDoesNotReadFileContents(t *testing.T) {
	store, root := openPageTestStore(t)
	path := filepath.Join(root, "unreadable.txt")
	if err := os.WriteFile(path, []byte("abc"), 0000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0600) })

	dir, err := store.openDirNoFollow(".")
	if err != nil {
		t.Fatal(err)
	}
	defer dir.Close()
	info, err := statEntryNoFollow(dir, "unreadable.txt")
	if err != nil {
		t.Fatalf("metadata lookup required read access: %v", err)
	}
	if !info.Mode().IsRegular() || info.Size() != 3 {
		t.Fatalf("metadata = %v size=%d", info.Mode(), info.Size())
	}
	if os.Geteuid() != 0 {
		// Without root, prove the old open-based path would have failed.
		if _, err := unix.Openat(int(dir.Fd()), "unreadable.txt", unix.O_RDONLY, 0); err == nil {
			t.Fatal("test setup lost the unreadable permission")
		}
	}

	if err := os.Symlink(path, filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	if _, err := statEntryNoFollow(dir, "link"); err != ErrType {
		t.Fatalf("symlink metadata = %v, want %v", err, ErrType)
	}
}

// A small page must not stat names that cannot enter the selection, and must
// never retain more than limit+1 candidates regardless of readdir order.
func TestPageSmallPageUsesBoundedMetadataWork(t *testing.T) {
	store, root := openPageTestStore(t)
	const total = 2000
	for i := 0; i < total; i++ {
		name := fmt.Sprintf("file-%04d.dat", i)
		if err := os.WriteFile(filepath.Join(root, name), []byte("x"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	statCalls := 0
	store.statEntry = func(dir *os.File, name string) (os.FileInfo, error) {
		statCalls++
		return statEntryNoFollow(dir, name)
	}

	entries, next, err := store.Page(".", "", 8)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 8 || next != "file-0007.dat" {
		t.Fatalf("page = %d entries, next %q", len(entries), next)
	}
	for i, entry := range entries {
		want := fmt.Sprintf("file-%04d.dat", i)
		if entry.Name != want {
			t.Fatalf("entry %d = %q, want %q", i, entry.Name, want)
		}
	}
	// Reading every name is unavoidable for an unsorted readdir, but only
	// names that beat the retained maximum need metadata.
	if statCalls >= total/4 {
		t.Fatalf("stat'ed %d of %d entries for a page of 8", statCalls, total)
	}
}

// Paging through a directory whose readdir order is unrelated to name order
// must still visit every entry exactly once in sorted order.
func TestPageCursorIsStableWithUnsortedDirectory(t *testing.T) {
	store, root := openPageTestStore(t)
	const total = 257
	// Creation order is deliberately not name order.
	for i := total - 1; i >= 0; i-- {
		name := fmt.Sprintf("item-%03d", i)
		if err := os.WriteFile(filepath.Join(root, name), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	var got []string
	cursor := ""
	for pages := 0; ; pages++ {
		if pages > total {
			t.Fatal("pagination did not terminate")
		}
		entries, next, err := store.Page(".", cursor, 7)
		if err != nil {
			t.Fatal(err)
		}
		for _, entry := range entries {
			got = append(got, entry.Name)
		}
		if next == "" {
			break
		}
		if next != entries[len(entries)-1].Name {
			t.Fatalf("cursor %q is not the last returned entry", next)
		}
		cursor = next
	}
	if len(got) != total {
		t.Fatalf("visited %d entries, want %d", len(got), total)
	}
	for i, name := range got {
		want := fmt.Sprintf("item-%03d", i)
		if name != want {
			t.Fatalf("entry %d = %q, want %q", i, name, want)
		}
	}
}

func TestPageSkipsSymlinksAndFifos(t *testing.T) {
	store, root := openPageTestStore(t)
	if err := os.WriteFile(filepath.Join(root, "real.txt"), []byte("data"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "real.txt"), filepath.Join(root, "link.txt")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "missing"), filepath.Join(root, "dangling")); err != nil {
		t.Fatal(err)
	}
	if err := unix.Mkfifo(filepath.Join(root, "pipe"), 0600); err != nil {
		t.Fatal(err)
	}

	entries, _, err := store.Page(".", "", 10)
	if err != nil {
		t.Fatalf("unsupported entry broke pagination: %v", err)
	}
	if len(entries) != 1 || entries[0].Name != "real.txt" {
		t.Fatalf("Page returned unsupported entries: %+v", entries)
	}
}

func TestPageSkipsInternalStagingNames(t *testing.T) {
	store, root := openPageTestStore(t)
	for _, name := range []string{".lightisle-upload-abc", ".lightisle-trashmeta-def", "normal.txt"} {
		if err := os.WriteFile(filepath.Join(root, name), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	entries, _, err := store.Page(".", "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || !strings.HasSuffix(entries[0].Name, "normal.txt") {
		t.Fatalf("internal names leaked: %+v", entries)
	}
}

func TestPagePropagatesGenuineMetadataErrors(t *testing.T) {
	store, root := openPageTestStore(t)
	for _, name := range []string{"a.txt", "b.txt"} {
		if err := os.WriteFile(filepath.Join(root, name), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	store.statEntry = func(*os.File, string) (os.FileInfo, error) {
		return nil, syscall.EIO
	}
	if _, _, err := store.Page(".", "", 10); err == nil {
		t.Fatal("I/O error was silently swallowed")
	}
}
