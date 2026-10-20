package files

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestPageSkipsUnixSocketEntries(t *testing.T) {
	root, err := os.MkdirTemp("/private/tmp", "li-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	store, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := os.WriteFile(filepath.Join(root, "visible.txt"), []byte("ok"), 0600); err != nil {
		t.Fatal(err)
	}
	socket, err := net.Listen("unix", filepath.Join(root, "local.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()

	entries, _, err := store.Page(".", "", 10)
	if err != nil {
		t.Fatalf("socket entry broke pagination: %v", err)
	}
	if len(entries) != 1 || entries[0].Name != "visible.txt" {
		t.Fatalf("Page returned unsupported entries: %+v", entries)
	}
}
