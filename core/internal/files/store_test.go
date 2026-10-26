package files

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSandboxAndTrash(t *testing.T) {
	dir := t.TempDir()
	store, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	bad := []string{"../secret", "a/../../x", "/etc/passwd", ".lightisle-trash", "a//b", "a/./b", "a\\b"}
	for _, name := range bad {
		if _, _, err := store.Read(name); !errors.Is(err, ErrPath) {
			t.Errorf("unsafe read %q returned %v", name, err)
		}
	}
	if err := store.Mkdir("Photos"); err != nil {
		t.Fatal(err)
	}
	if n, err := store.Upload("Photos/hello.txt", strings.NewReader("LightIsle")); err != nil || n != 9 {
		t.Fatalf("upload %v %d", err, n)
	}
	if _, err := store.Upload("Photos/hello.txt", strings.NewReader("overwrite")); !errors.Is(err, ErrExists) {
		t.Fatalf("overwritten existing file: %v", err)
	}
	entries, err := store.List("Photos")
	if err != nil || len(entries) != 1 || entries[0].Name != "hello.txt" {
		t.Fatalf("listing %#v %v", entries, err)
	}
	f, fi, err := store.Read("Photos/hello.txt")
	if err != nil {
		t.Fatal(err)
	}
	data, err := io.ReadAll(f)
	f.Close()
	if err != nil || string(data) != "LightIsle" || fi.Size() != 9 {
		t.Fatal("download mismatch")
	}
	outside := filepath.Join(t.TempDir(), "private.txt")
	if err := os.WriteFile(outside, []byte("private"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dir, "Photos", "outside.txt")); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Read("Photos/outside.txt"); err == nil {
		t.Fatal("escaped root via symlink")
	}
	if err := store.MoveToTrash("Photos/hello.txt"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Read("Photos/hello.txt"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("trashed item available: %v", err)
	}
	trashed, err := store.TrashList()
	if err != nil || len(trashed) != 1 || trashed[0].OriginalPath != "Photos/hello.txt" {
		t.Fatalf("trash metadata: %#v %v", trashed, err)
	}
	if _, err := store.Upload("Photos/hello.txt", strings.NewReader("newer")); err != nil {
		t.Fatal(err)
	}
	if err := store.Restore(trashed[0].ID); !errors.Is(err, ErrExists) {
		t.Fatalf("restore overwrote new file: %v", err)
	}
	if err := store.MoveToTrash("Photos/hello.txt"); err != nil {
		t.Fatal(err)
	}
	if err := store.Restore(trashed[0].ID); err != nil {
		t.Fatal(err)
	}
	restored, _, err := store.Read("Photos/hello.txt")
	if err != nil {
		t.Fatal(err)
	}
	restoredBytes, err := io.ReadAll(restored)
	restored.Close()
	if err != nil || string(restoredBytes) != "LightIsle" {
		t.Fatalf("wrong restored data: %q %v", restoredBytes, err)
	}
	if trashEntries, err := store.TrashList(); err != nil || len(trashEntries) != 1 {
		t.Fatalf("expected second deleted version in trash: %#v %v", trashEntries, err)
	}
	if list, err := store.List("."); err != nil || len(list) != 1 {
		t.Fatalf("root list %#v: %v", list, err)
	}
	if err := store.MoveToTrash("."); !errors.Is(err, ErrPath) {
		t.Fatal("allowed trashing root")
	}
}

type zeroReader struct{}

func (zeroReader) Read(buffer []byte) (int, error) {
	for i := range buffer {
		buffer[i] = 0
	}
	return len(buffer), nil
}

// A finished multi-gigabyte download publishes from local staging; only HTTP
// request bodies are bounded by maxUpload. The real ≥1 GiB acceptance download
// failed at publish time with download_publish_failed before this split.
func TestPublishLocalAcceptsBeyondRequestCap(t *testing.T) {
	dir := t.TempDir()
	store, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	size := int64(maxUpload + 1)
	if _, err := store.Upload("cap.txt", io.LimitReader(zeroReader{}, size)); !errors.Is(err, ErrSize) {
		t.Fatalf("request-sized upload beyond cap = %v", err)
	}
	if err := store.Mkdir("iso"); err != nil {
		t.Fatal(err)
	}
	published, err := store.PublishLocal("iso/ubuntu.iso", io.LimitReader(zeroReader{}, size))
	if err != nil || published != size {
		t.Fatalf("local publish beyond cap = %d %v", published, err)
	}
	_, info, err := store.Read("iso/ubuntu.iso")
	if err != nil || info.Size() != size {
		t.Fatalf("published size mismatch: %v %v", info, err)
	}
}
