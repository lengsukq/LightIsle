package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNativeMoveCannotBypassPersonalStorageLedger(t *testing.T) {
	for _, source := range []string{
		"Users", "Users/u2/files/report.txt", "users/u2/photos/x.jpg",
		"USERS/u3/videos/film.mkv",
	} {
		if !nativeMoveTouchesPersonalHome(source) {
			t.Errorf("native move escaped protected namespace: %q", source)
		}
	}
	for _, source := range []string{
		"family/report.txt", "UsersArchive/file.txt", "images/Users/file",
		"Users2/u3/file", "users_backup",
	} {
		if nativeMoveTouchesPersonalHome(source) {
			t.Errorf("ordinary shared file unexpectedly blocked: %q", source)
		}
	}
}

func TestNativeExportCannotWriteDirectlyIntoAnotherRegisteredDisk(t *testing.T) {
	base := t.TempDir()
	first := filepath.Join(base, "disk-one")
	second := filepath.Join(base, "disk-two")
	outside := filepath.Join(base, "external-export")
	for _, folder := range []string{first, second, outside} {
		if err := os.Mkdir(folder, 0700); err != nil {
			t.Fatal(err)
		}
	}
	privateHome := filepath.Join(second, "Users", "u7", "photos")
	if err := os.MkdirAll(privateHome, 0700); err != nil {
		t.Fatal(err)
	}
	for _, destination := range []string{first, second, privateHome, base} {
		if !nativeExportOverlapsRegisteredRoot(destination, []string{first, second}) {
			t.Fatalf("NAS root overlap escaped native export guard: %q", destination)
		}
	}
	if nativeExportOverlapsRegisteredRoot(outside, []string{first, second}) {
		t.Fatal("independent non-NAS export destination was incorrectly blocked")
	}
}
