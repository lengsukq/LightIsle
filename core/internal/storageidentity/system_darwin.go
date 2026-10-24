//go:build darwin

package storageidentity

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	diskutilTimeout  = 3 * time.Second
	diskutilMaxBytes = 256 * 1024
)

type directoryIdentity struct {
	id       uint64
	birthSec int64
	birthNS  int64
	gen      uint64
}

type mountIdentity struct {
	point string
	fsid  [2]int32 // only an in-call stability check; never persisted as a UUID.
}

func (SystemProvider) Capture(ctx context.Context, path string) (Binding, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	resolved, err := normalizedPath(path)
	if err != nil {
		return Binding{}, err
	}
	beforeInfo, beforeDir, err := statDirectory(resolved)
	if err != nil {
		return Binding{}, err
	}
	beforeMount, err := statMount(resolved)
	if err != nil {
		return Binding{}, err
	}
	volumeUUID, diskutilMount, err := readVolumeUUID(ctx, beforeMount.point)
	if err != nil {
		return Binding{}, err
	}
	if diskutilMount != beforeMount.point {
		return Binding{}, fmt.Errorf("%w: statfs=%q diskutil=%q", ErrMountPoint, beforeMount.point, diskutilMount)
	}
	afterInfo, afterDir, err := statDirectory(resolved)
	if err != nil {
		return Binding{}, err
	}
	afterMount, err := statMount(resolved)
	if err != nil {
		return Binding{}, err
	}
	if beforeDir != afterDir || !os.SameFile(beforeInfo, afterInfo) ||
		beforeMount.point != afterMount.point || beforeMount.fsid != afterMount.fsid {
		return Binding{}, ErrUnstableDirectory
	}
	binding := Binding{
		Path:        resolved,
		VolumeUUID:  volumeUUID,
		DirectoryID: afterDir.id,
		BirthSec:    afterDir.birthSec,
		BirthNsec:   afterDir.birthNS,
		Generation:  afterDir.gen,
	}
	if err := binding.Validate(); err != nil {
		return Binding{}, err
	}
	return binding, nil
}

func (p SystemProvider) Verify(ctx context.Context, expected Binding) error {
	if err := expected.Validate(); err != nil {
		return err
	}
	actual, err := p.Capture(ctx, expected.Path)
	if err != nil {
		return err
	}
	if !Equal(actual, expected) {
		return ErrMismatch
	}
	return nil
}

// IsVolumeMounted searches mounted local disk-backed filesystems by durable
// VolumeUUID. Mount paths and volume names can change when a drive reconnects.
func (p SystemProvider) IsVolumeMounted(parent context.Context, volumeUUID string) (bool, error) {
	wanted, err := normalizeUUID(volumeUUID)
	if err != nil {
		return false, err
	}
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, 12*time.Second)
	defer cancel()
	const mntNowait = 2 // macOS getfsstat(2) MNT_NOWAIT
	count, err := syscall.Getfsstat(nil, mntNowait)
	if err != nil || count < 0 || count > 256 {
		if err == nil {
			err = ErrMountPoint
		}
		return false, fmt.Errorf("cannot enumerate mounted volumes: %w", err)
	}
	if count == 0 {
		return false, nil
	}
	stats := make([]syscall.Statfs_t, count)
	count, err = syscall.Getfsstat(stats, mntNowait)
	if err != nil || count < 0 || count > len(stats) {
		if err == nil {
			err = ErrMountPoint
		}
		return false, fmt.Errorf("cannot enumerate mounted volumes: %w", err)
	}
	seen := make(map[string]struct{}, count)
	for _, stat := range stats[:count] {
		mount := filepath.Clean(cString(stat.Mntonname[:]))
		device := cString(stat.Mntfromname[:])
		if !filepath.IsAbs(mount) || !strings.HasPrefix(device, "/dev/disk") {
			continue
		}
		if _, ok := seen[mount]; ok {
			continue
		}
		seen[mount] = struct{}{}
		actual, _, readErr := readVolumeUUID(ctx, mount)
		if readErr != nil {
			return false, fmt.Errorf("cannot verify mounted volume %q: %w", mount, readErr)
		}
		if strings.EqualFold(actual, wanted) {
			return true, nil
		}
	}
	return false, nil
}

func statDirectory(path string) (os.FileInfo, directoryIdentity, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, directoryIdentity{}, fmt.Errorf("%w: %v", ErrInvalidPath, err)
	}
	if !info.IsDir() {
		return nil, directoryIdentity{}, ErrNotDirectory
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Ino == 0 || stat.Birthtimespec.Sec <= 0 || stat.Birthtimespec.Nsec < 0 ||
		stat.Birthtimespec.Nsec >= 1_000_000_000 {
		return nil, directoryIdentity{}, ErrIncomplete
	}
	return info, directoryIdentity{
		id:       stat.Ino,
		birthSec: stat.Birthtimespec.Sec,
		birthNS:  stat.Birthtimespec.Nsec,
		gen:      uint64(stat.Gen),
	}, nil
}

// MatchesDirectory ties a descriptor opened during verification to the
// recorded directory object. Checking the pathname twice alone misses an
// A -> B -> A replacement around OpenRoot.
func MatchesDirectory(binding Binding, info os.FileInfo) bool {
	if info == nil || !info.IsDir() {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Ino == binding.DirectoryID && stat.Birthtimespec.Sec == binding.BirthSec &&
		stat.Birthtimespec.Nsec == binding.BirthNsec && uint64(stat.Gen) == binding.Generation
}

func statMount(path string) (mountIdentity, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return mountIdentity{}, fmt.Errorf("%w: statfs: %v", ErrMountPoint, err)
	}
	point := filepath.Clean(cString(stat.Mntonname[:]))
	if !filepath.IsAbs(point) || point == "." {
		return mountIdentity{}, ErrMountPoint
	}
	return mountIdentity{point: point, fsid: stat.Fsid.Val}, nil
}

func cString(value []int8) string {
	var b strings.Builder
	for _, ch := range value {
		if ch == 0 {
			break
		}
		b.WriteByte(byte(ch))
	}
	return b.String()
}

type volumeInfo struct {
	volumeUUID string
	mountPoint string
}

func readVolumeUUID(parent context.Context, mountpoint string) (string, string, error) {
	ctx, cancel := context.WithTimeout(parent, diskutilTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/sbin/diskutil", "info", "-plist", mountpoint)
	var output cappedBuffer
	output.limit = diskutilMaxBytes
	cmd.Stdout = &output
	cmd.Stderr = io.Discard
	if err := cmd.Run(); output.overflow {
		return "", "", ErrOutputTooLarge
	} else if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return "", "", fmt.Errorf("diskutil timed out after %s", diskutilTimeout)
		}
		if ctx.Err() != nil {
			return "", "", ctx.Err()
		}
		return "", "", fmt.Errorf("diskutil volume lookup failed: %w", err)
	}
	info, err := parseVolumePlist(output.data)
	if err != nil {
		return "", "", err
	}
	uuid, err := normalizeUUID(info.volumeUUID)
	if err != nil {
		return "", "", err
	}
	if info.mountPoint == "" || !filepath.IsAbs(info.mountPoint) || filepath.Clean(info.mountPoint) != info.mountPoint {
		return "", "", ErrMountPoint
	}
	return uuid, info.mountPoint, nil
}

type cappedBuffer struct {
	data     []byte
	limit    int
	overflow bool
}

func (b *cappedBuffer) Write(value []byte) (int, error) {
	remaining := b.limit - len(b.data)
	if remaining <= 0 {
		b.overflow = b.overflow || len(value) > 0
		if b.overflow {
			return 0, ErrOutputTooLarge
		}
		return 0, nil
	}
	if len(value) > remaining {
		b.data = append(b.data, value[:remaining]...)
		b.overflow = true
		return remaining, ErrOutputTooLarge
	}
	b.data = append(b.data, value...)
	return len(value), nil
}

func parseVolumePlist(data []byte) (volumeInfo, error) {
	if len(data) == 0 || len(data) > diskutilMaxBytes {
		return volumeInfo{}, ErrOutputTooLarge
	}
	decoder := xml.NewDecoder(bytes.NewReader(data))
	next := func() (xml.Token, error) {
		for {
			token, err := decoder.Token()
			if err != nil {
				return nil, err
			}
			switch value := token.(type) {
			case xml.StartElement, xml.EndElement:
				return token, nil
			case xml.CharData:
				if strings.TrimSpace(string(value)) != "" {
					return nil, ErrIncomplete
				}
			}
		}
	}
	first, err := next()
	if err != nil {
		return volumeInfo{}, err
	}
	plist, ok := first.(xml.StartElement)
	if !ok || plist.Name.Local != "plist" {
		return volumeInfo{}, ErrIncomplete
	}
	token, err := next()
	if err != nil {
		return volumeInfo{}, err
	}
	dictionary, ok := token.(xml.StartElement)
	if !ok || dictionary.Name.Local != "dict" {
		return volumeInfo{}, ErrIncomplete
	}
	var info volumeInfo
	seen := map[string]bool{}
	for {
		token, err = next()
		if err != nil {
			return volumeInfo{}, err
		}
		if end, ok := token.(xml.EndElement); ok {
			if end.Name != dictionary.Name {
				return volumeInfo{}, ErrIncomplete
			}
			break
		}
		keyStart, ok := token.(xml.StartElement)
		if !ok || keyStart.Name.Local != "key" {
			return volumeInfo{}, ErrIncomplete
		}
		var key string
		if err := decoder.DecodeElement(&key, &keyStart); err != nil {
			return volumeInfo{}, err
		}
		token, err = next()
		if err != nil {
			return volumeInfo{}, err
		}
		valueStart, ok := token.(xml.StartElement)
		if !ok {
			return volumeInfo{}, ErrIncomplete
		}
		known := key == "VolumeUUID" || key == "MountPoint"
		if known && (seen[key] || valueStart.Name.Local != "string") {
			return volumeInfo{}, ErrIncomplete
		}
		if valueStart.Name.Local == "string" {
			var value string
			if err := decoder.DecodeElement(&value, &valueStart); err != nil {
				return volumeInfo{}, err
			}
			switch key {
			case "VolumeUUID":
				info.volumeUUID = value
			case "MountPoint":
				info.mountPoint = value
			}
		} else if err := decoder.Skip(); err != nil {
			return volumeInfo{}, err
		}
		seen[key] = true
	}
	token, err = next()
	if err != nil {
		return volumeInfo{}, err
	}
	end, ok := token.(xml.EndElement)
	if !ok || end.Name != plist.Name {
		return volumeInfo{}, ErrIncomplete
	}
	if _, err = next(); !errors.Is(err, io.EOF) {
		return volumeInfo{}, ErrIncomplete
	}
	if info.volumeUUID == "" || info.mountPoint == "" {
		return volumeInfo{}, ErrIncomplete
	}
	return info, nil
}
