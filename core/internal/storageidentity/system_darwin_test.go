//go:build darwin

package storageidentity

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVolumePlistUsesTopLevelDictionaryAndRejectsAmbiguity(t *testing.T) {
	const uuid = "12345678-1234-1234-1234-123456789abc"
	valid := `<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Nested</key><dict><key>VolumeUUID</key><string>wrong</string></dict><key>Writable</key><true/><key>VolumeUUID</key><string>` + uuid + `</string><key>MountPoint</key><string>/System/Volumes/Data</string></dict></plist>`
	info, err := parseVolumePlist([]byte(valid))
	if err != nil || info.volumeUUID != uuid || info.mountPoint != "/System/Volumes/Data" {
		t.Fatalf("normal diskutil plist not parsed: %+v %v", info, err)
	}
	for _, bad := range []string{
		strings.Replace(valid, "<key>Writable</key><true/>", "<key>VolumeUUID</key><string>another</string>", 1),
		strings.Replace(valid, "<key>MountPoint</key><string>/System/Volumes/Data</string>", "<key>MountPoint</key><integer>1</integer>", 1),
		strings.Replace(valid, "<key>VolumeUUID</key><string>"+uuid+"</string>", "", 1),
		valid + `<dict/>`,
		strings.TrimSuffix(valid, "</plist>"),
	} {
		if _, err := parseVolumePlist([]byte(bad)); err == nil {
			t.Fatal("ambiguous or truncated plist accepted")
		}
	}
}

func TestSystemCaptureVerifiesRealDirectoryAndDetectsReplacement(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "selected")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	binding, err := Capture(context.Background(), dir)
	if err != nil {
		t.Fatal("real local disk identity capture failed:", err)
	}
	mounted, err := (SystemProvider{}).IsVolumeMounted(context.Background(), binding.VolumeUUID)
	if err != nil || !mounted {
		t.Fatalf("current local volume was not found by UUID: mounted=%v err=%v", mounted, err)
	}
	if err := Verify(context.Background(), binding); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(dir, dir+"-previous"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := Verify(context.Background(), binding); !errors.Is(err, ErrMismatch) {
		t.Fatalf("replacement directory was accepted: %v", err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Capture(context.Background(), home); err != nil {
		t.Fatal("APFS home firmlink identity rejected:", err)
	}
}
