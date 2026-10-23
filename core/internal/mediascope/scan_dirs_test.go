package mediascope

import "testing"

func TestScanDirectoriesNormalizeAndRejectEscapes(t *testing.T) {
	got, err := ScanDirectories([]string{"photos/2026", "photos", "movies", "movies", "photos/2026/x"})
	if err != nil || len(got) != 2 || got[0] != "movies" || got[1] != "photos" {
		t.Fatalf("%v %v", got, err)
	}
	for _, invalid := range [][]string{{}, {"/tmp"}, {""}, {"../etc"}, {"a/../b"}, {"a//b"}, {"." + "./secret"}, {"a\\b"}, {"a\nfoo"}} {
		if _, err := ScanDirectories(invalid); err == nil {
			t.Errorf("unsafe scope accepted %#v", invalid)
		}
	}
	full, err := ScanDirectories([]string{"x", "."})
	if err != nil || len(full) != 1 || full[0] != "." {
		t.Fatalf("%v %v", full, err)
	}
}
