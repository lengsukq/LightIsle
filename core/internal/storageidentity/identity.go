// Package storageidentity captures a directory's durable relationship to a
// mounted volume. VolumeUUID is obtained from diskutil on macOS; filesystem
// device numbers are never persisted as a substitute for a volume UUID.
package storageidentity

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
)

var (
	ErrUnsupported       = errors.New("storage_identity_unsupported")
	ErrInvalidPath       = errors.New("storage_identity_invalid_path")
	ErrNotDirectory      = errors.New("storage_identity_not_directory")
	ErrIncomplete        = errors.New("storage_identity_incomplete")
	ErrMismatch          = errors.New("storage_identity_mismatch")
	ErrMountPoint        = errors.New("storage_identity_mountpoint_mismatch")
	ErrOutputTooLarge    = errors.New("storage_identity_diskutil_output_too_large")
	ErrUnstableDirectory = errors.New("storage_identity_changed_during_capture")
)

// Binding records the selected path and the identity of the directory and
// mounted volume currently found there. DirectoryID, birth time and
// Generation come from the directory's stat identity. VolumeUUID comes from
// diskutil, not st_dev/statfs.fsid.
type Binding struct {
	Path        string `json:"path"`
	VolumeUUID  string `json:"volume_uuid"`
	DirectoryID uint64 `json:"directory_id"`
	BirthSec    int64  `json:"birth_sec"`
	BirthNsec   int64  `json:"birth_nsec"`
	Generation  uint64 `json:"generation"`
}

// Provider permits callers and tests to substitute volume identity reads.
// Production code should use SystemProvider or the package-level helpers.
type Provider interface {
	Capture(context.Context, string) (Binding, error)
	Verify(context.Context, Binding) error
}

// SystemProvider reads directory identity and the containing mount's UUID
// using local macOS system interfaces.
type SystemProvider struct{}

func Capture(ctx context.Context, path string) (Binding, error) {
	return SystemProvider{}.Capture(ctx, path)
}

func Verify(ctx context.Context, binding Binding) error {
	return SystemProvider{}.Verify(ctx, binding)
}

// Equal reports whether two persisted bindings are identical, including the
// selected canonical path.
func Equal(a, b Binding) bool { return a == b }

// Same reports whether two bindings identify the same directory on the same
// volume, even if the directory is currently reachable through another mount
// path. It intentionally ignores Path.
func Same(a, b Binding) bool {
	if a.Validate() != nil || b.Validate() != nil {
		return false
	}
	return a.VolumeUUID == b.VolumeUUID &&
		a.DirectoryID == b.DirectoryID &&
		a.BirthSec == b.BirthSec &&
		a.BirthNsec == b.BirthNsec &&
		a.Generation == b.Generation
}

// SameObject is an explicit alias for Same, useful at call sites that compare
// a root across a mount-path change.
func SameObject(a, b Binding) bool { return Same(a, b) }

func (b Binding) Validate() error {
	if !filepath.IsAbs(b.Path) || filepath.Clean(b.Path) != b.Path ||
		b.VolumeUUID == "" || b.DirectoryID == 0 || b.BirthSec <= 0 ||
		b.BirthNsec < 0 || b.BirthNsec >= 1_000_000_000 {
		return ErrIncomplete
	}
	if !validUUID(b.VolumeUUID) {
		return fmt.Errorf("%w: invalid volume UUID", ErrIncomplete)
	}
	return nil
}

func validUUID(value string) bool {
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return false
	}
	for i, r := range value {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			continue
		}
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f' || r >= 'A' && r <= 'F') {
			return false
		}
	}
	return true
}

func normalizedPath(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", ErrInvalidPath
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrInvalidPath, err)
	}
	if !filepath.IsAbs(resolved) {
		return "", ErrInvalidPath
	}
	return filepath.Clean(resolved), nil
}

func normalizeUUID(value string) (string, error) {
	value = strings.TrimSpace(value)
	if !validUUID(value) {
		return "", fmt.Errorf("%w: missing or invalid VolumeUUID", ErrIncomplete)
	}
	return strings.ToUpper(value), nil
}
