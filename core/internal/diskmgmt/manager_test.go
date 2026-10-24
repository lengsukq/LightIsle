package diskmgmt

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"strings"
	"testing"
	"time"
)

func volumePlist(id, uuid, name, mount string, internal bool) []byte {
	boolText := "false"
	if internal {
		boolText = "true"
	}
	return []byte(fmt.Sprintf(`<?xml version="1.0"?><plist><dict>
<key>DeviceIdentifier</key><string>%s</string>
<key>PartOfWhole</key><string>disk8</string>
<key>Internal</key><%s/>
<key>WholeDisk</key><false/>
<key>VolumeUUID</key><string>%s</string>
<key>VolumeName</key><string>%s</string>
<key>MountPoint</key><string>%s</string>
<key>FilesystemName</key><string>Windows NT File System (NTFS)</string>
<key>BusProtocol</key><string>USB</string>
<key>SMARTStatus</key><string>Not Supported</string>
<key>ReadOnlyVolume</key><true/>
</dict></plist>`, id, boolText, uuid, name, mount))
}

func TestCurrentMacDiskDiscoveryIsReadOnly(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS-only read-only disk enumeration")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	drives, err := New().List(ctx)
	if err != nil {
		t.Fatalf("read-only diskutil list failed: %v", err)
	}
	for _, d := range drives {
		if !d.External || !deviceRule.MatchString(d.ID) {
			t.Fatalf("invalid external volume: %+v", d)
		}
	}
	t.Logf("inspected %d external volumes without disk modifications", len(drives))
}
func TestDriveInfoAndRejectUnsafeChanges(t *testing.T) {
	ctx := context.Background()
	calls := []string{}
	raw := volumePlist("disk8s1", "11111111-2222-3333-4444-555555555555", "Untitled", "/Volumes/Untitled", false)
	m := New()
	m.run = func(_ context.Context, args ...string) ([]byte, error) {
		command := strings.Join(args, " ")
		calls = append(calls, command)
		switch command {
		case "list -plist external":
			return []byte("<plist><dict><key>DeviceIdentifier</key><string>disk8s1</string></dict></plist>"), nil
		case "info -plist disk8s1":
			return raw, nil
		case "rename disk8s1 USB Archive":
			return []byte("ok"), nil
		case "eject disk8":
			return []byte("ok"), nil
		default:
			return nil, fmt.Errorf("unexpected command: %s", command)
		}
	}
	disks, err := m.List(ctx)
	if err != nil || len(disks) != 1 {
		t.Fatalf("list: %+v %v", disks, err)
	}
	d := disks[0]
	if d.ID != "disk8s1" || d.Filesystem != "Windows NT File System (NTFS)" ||
		d.Protocol != "USB" || d.SMART != "Not Supported" || !d.ReadOnly || d.Identity == "" {
		t.Fatalf("incorrect disk model: %+v", d)
	}
	for _, req := range []Request{
		{Action: "rename", ID: "disk0s1", Identity: d.Identity, Name: "ABC"},
		{Action: "rename", ID: "disk8s1", Identity: d.Identity, Name: "../../root"},
		{Action: "rename", ID: "disk8s1", Identity: d.Identity, Name: "bad\nname"},
		{Action: "eject", ID: "disk8s1", Identity: strings.Repeat("1", 64)},
	} {
		before := len(calls)
		if _, err := m.Do(ctx, req); err == nil {
			t.Fatalf("unsafe request allowed: %+v", req)
		}
		for _, call := range calls[before:] {
			if strings.HasPrefix(call, "rename ") || strings.HasPrefix(call, "eject ") {
				t.Fatalf("unsafe diskutil mutation executed: %s", call)
			}
		}
	}
	m.SetGuard(func(Disk, string) error { return ErrProtected })
	if _, err := m.Do(ctx, Request{Action: "eject", ID: d.ID, Identity: d.Identity}); !errors.Is(err, ErrProtected) {
		t.Fatalf("NAS guard bypassed: %v", err)
	}
	m.SetGuard(nil)
	raw = volumePlist("disk8s1", "22222222-2222-3333-4444-555555555555", "Untitled", "/Volumes/Untitled", false)
	if _, err := m.Do(ctx, Request{Action: "eject", ID: d.ID, Identity: d.Identity}); !errors.Is(err, ErrChanged) {
		t.Fatalf("device swap was not detected: %v", err)
	}
	raw = volumePlist("disk8s1", "11111111-2222-3333-4444-555555555555", "Untitled", "/Volumes/Untitled", false)
	if _, err := m.Do(ctx, Request{Action: "rename", ID: d.ID, Identity: d.Identity, Name: "USB Archive"}); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Do(ctx, Request{Action: "eject", ID: d.ID, Identity: d.Identity}); err != nil {
		t.Fatal(err)
	}
}

func TestVolumeGuardUsesStableUUIDAcrossMountPathChanges(t *testing.T) {
	rootUUID := "11111111-2222-3333-4444-555555555555"
	disk, err := details(map[string]string{
		"DeviceIdentifier": "disk8s1",
		"PartOfWhole":      "disk8",
		"Internal":         "false",
		"VolumeName":       "Renamed",
		"MountPoint":       "/Volumes/Renamed",
		"VolumeUUID":       rootUUID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !MatchesVolumeUUID(disk, rootUUID) {
		t.Fatal("same bound volume was not protected after its mount path changed")
	}
	if MatchesVolumeUUID(disk, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee") {
		t.Fatal("a sibling volume on the same physical device matched by parent or name")
	}
}

func TestInternalAndMissingIdentityNeverMutable(t *testing.T) {
	for _, bad := range [][]byte{
		volumePlist("disk8s1", "aaa", "Internal", "/", true),
		volumePlist("disk8s1", "", "NoUUID", "/Volumes/NoUUID", false),
	} {
		fields, err := infoFields(bad)
		if err != nil {
			t.Fatal(err)
		}
		d, err := details(fields)
		if fields["Internal"] == "true" && !errors.Is(err, ErrUnsupported) {
			t.Fatal("internal drive accepted")
		}
		if err == nil && d.Identity != "" && fields["VolumeUUID"] == "" {
			t.Fatal("missing stable identity considered safe")
		}
	}
}
