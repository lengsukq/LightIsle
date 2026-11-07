//go:build darwin

package files

import (
	"errors"
	"io/fs"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

func validControlledAlbumLeaf(name string) bool {
	if name == "" || name == "." || name == ".." ||
		strings.ContainsAny(name, "/\\\x00") || IsInternalName(name) {
		return false
	}
	return true
}

func validControlledAlbumSymlinkTarget(targetRel string) bool {
	parts := strings.Split(targetRel, "/")
	if len(parts) != 5 || parts[0] != ".." || parts[1] != ".." || parts[3] != "photos" {
		return false
	}
	if !strings.HasPrefix(parts[2], "u") || len(parts[2]) < 2 {
		return false
	}
	uid, err := strconv.ParseInt(parts[2][1:], 10, 64)
	if err != nil || uid <= 0 {
		return false
	}
	return validControlledAlbumLeaf(parts[4])
}

func readlinkAt(dirfd int, name string) (string, error) {
	var st unix.Stat_t
	if err := unix.Fstatat(dirfd, name, &st, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return "", err
	}
	if st.Mode&unix.S_IFMT != unix.S_IFLNK {
		return "", ErrType
	}
	buf := make([]byte, 1024)
	n, err := unix.Readlinkat(dirfd, name, buf)
	if err != nil {
		return "", err
	}
	if n <= 0 || n >= len(buf) {
		return "", ErrPath
	}
	return string(buf[:n]), nil
}

// CreateControlledAlbumSymlink creates a relative symlink inside a recipient's
// photos directory pointing only to ../../u<owner>/photos/<album>. If the exact
// same controlled symlink already exists, the call is idempotent.
func (s *Store) CreateControlledAlbumSymlink(memberPhotosDir, linkName, targetRel string) error {
	dirPath, err := s.safePath(memberPhotosDir, false, false)
	if err != nil {
		return err
	}
	if !validControlledAlbumLeaf(linkName) || !validControlledAlbumSymlinkTarget(targetRel) {
		return ErrPath
	}
	parent, err := s.openDirNoFollow(dirPath)
	if err != nil {
		return err
	}
	defer parent.Close()
	if err := unix.Symlinkat(targetRel, int(parent.Fd()), linkName); err != nil {
		if errors.Is(err, unix.EEXIST) || errors.Is(err, fs.ErrExist) {
			if actual, rerr := readlinkAt(int(parent.Fd()), linkName); rerr == nil && actual == targetRel {
				return nil
			}
			return ErrExists
		}
		return err
	}
	return s.syncDirContents(parent)
}

// RemoveControlledAlbumSymlink unlinks only a symlink inside memberPhotosDir
// whose target matches expectedTarget. A real file or directory is never removed.
func (s *Store) RemoveControlledAlbumSymlink(memberPhotosDir, linkName, expectedTarget string) error {
	dirPath, err := s.safePath(memberPhotosDir, false, false)
	if err != nil {
		return err
	}
	if !validControlledAlbumLeaf(linkName) || !validControlledAlbumSymlinkTarget(expectedTarget) {
		return ErrPath
	}
	parent, err := s.openDirNoFollow(dirPath)
	if err != nil {
		return err
	}
	defer parent.Close()
	actual, err := readlinkAt(int(parent.Fd()), linkName)
	if errors.Is(err, unix.ENOENT) || errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if actual != expectedTarget {
		return ErrType
	}
	if err := unix.Unlinkat(int(parent.Fd()), linkName, 0); err != nil && !errors.Is(err, unix.ENOENT) {
		return err
	}
	return s.syncDirContents(parent)
}

func (m *Manager) CreateControlledAlbumSymlink(memberPhotosDir, linkName, targetRel string) error {
	return m.withRead(func(store *Store) error {
		return store.CreateControlledAlbumSymlink(memberPhotosDir, linkName, targetRel)
	})
}

func (m *Manager) RemoveControlledAlbumSymlink(memberPhotosDir, linkName, expectedTarget string) error {
	return m.withRead(func(store *Store) error {
		return store.RemoveControlledAlbumSymlink(memberPhotosDir, linkName, expectedTarget)
	})
}
