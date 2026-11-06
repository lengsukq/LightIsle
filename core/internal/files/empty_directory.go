//go:build darwin

package files

import (
	"errors"
	"io/fs"
	"path"

	"golang.org/x/sys/unix"
)

// ErrDirectoryNotEmpty means an album still contains files or subfolders.
var ErrDirectoryNotEmpty = errors.New("directory_not_empty")

// RemoveEmptyDirectory removes only an empty directory using the held parent
// descriptor. Unlinkat's atomic directory-empty check also protects against a
// concurrent writer: an album containing any file is never removed.
func (s *Store) RemoveEmptyDirectory(raw string) error {
	target, err := s.safePath(raw, false, false)
	if err != nil {
		return err
	}
	parent, err := s.openDirNoFollow(path.Dir(target))
	if err != nil {
		return err
	}
	defer parent.Close()
	info, err := statEntryNoFollow(parent, path.Base(target))
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return ErrType
	}
	if err := unix.Unlinkat(int(parent.Fd()), path.Base(target), unix.AT_REMOVEDIR); err != nil {
		if errors.Is(err, unix.ENOTEMPTY) || errors.Is(err, unix.EEXIST) {
			return ErrDirectoryNotEmpty
		}
		if errors.Is(err, unix.ENOENT) {
			return fs.ErrNotExist
		}
		return err
	}
	if err := parent.Sync(); err != nil {
		return ErrStorageSync
	}
	return nil
}

func (m *Manager) RemoveEmptyDirectory(raw string) error {
	return m.withRead(func(store *Store) error { return store.RemoveEmptyDirectory(raw) })
}
