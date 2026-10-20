package files

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDescriptorDirectoryTraversal(t *testing.T) {
	s, e := Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	if e = s.Mkdir("sub"); e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(filepath.Join(s.root.Name(), "sub", "a.txt"), []byte("abc"), 0600); e != nil {
		t.Fatal(e)
	}
	f, e := s.openDirNoFollow("sub")
	if e != nil {
		t.Fatal(e)
	}
	defer f.Close()
	names, e := f.Readdirnames(-1)
	if e != nil || len(names) != 1 || names[0] != "a.txt" {
		t.Fatalf("anchored directory listing: %v %v", names, e)
	}
	other, e := s.openDirNoFollow("sub")
	if e != nil {
		t.Fatal(e)
	}
	defer other.Close()
	info, e := statEntryNoFollow(other, "a.txt")
	if e != nil || !info.Mode().IsRegular() || info.Size() != 3 {
		t.Fatalf("anchored metadata: %v %v", info, e)
	}
	entries, e := s.List("sub")
	if e != nil || len(entries) != 1 || entries[0].Name != "a.txt" {
		t.Fatalf("public listing via anchored FD: %+v %v", entries, e)
	}
}
