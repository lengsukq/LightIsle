//go:build darwin

package files

import (
	"errors"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// openDirNoFollow descends from the already-open share root using O_NOFOLLOW
// on *every component*. No path reopening by absolute name is allowed.
// The directory file descriptor remains bound to its inode when another
// process renames or replaces a parent during an operation.
func (s *Store) openDirNoFollow(relative string) (*os.File, error) {
	if _, err := validate(relative, true); err != nil {
		return nil, err
	}
	current, err := s.root.Open(".")
	if err != nil {
		return nil, err
	}
	if relative == "." {
		return current, nil
	}
	for _, component := range strings.Split(relative, "/") {
		fd, err := unix.Openat(int(current.Fd()), component,
			unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
		if err != nil {
			current.Close()
			return nil, err
		}
		// Go DirEntry.Info falls back to Lstat(f.Name()+"/"+entry).
		// Preserve a useful rooted name for diagnostics, while production
		// enumeration uses statEntryNoFollow with the held dirfd instead.
		next := os.NewFile(uintptr(fd), filepath.Join(s.root.Name(), relative))
		current.Close()
		current = next
	}
	return current, nil
}

func statEntryNoFollow(dir *os.File, name string) (os.FileInfo, error) {
	fd, err := unix.Openat(int(dir.Fd()), name,
		unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), name)
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() && !info.IsDir() {
		return nil, ErrType
	}
	return info, nil
}

// openFileNoFollow excludes races where another process replaces the leaf
// file with a symbolic link pointing at a private sibling of a granted path.
func (s *Store) openFileNoFollow(relative string) (*os.File, error) {
	if _, err := validate(relative, false); err != nil {
		return nil, err
	}
	parent, err := s.openDirNoFollow(path.Dir(relative))
	if err != nil {
		return nil, err
	}
	defer parent.Close()
	fd, err := unix.Openat(int(parent.Fd()), path.Base(relative),
		unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), path.Base(relative))
	stat, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	if !stat.Mode().IsRegular() {
		f.Close()
		return nil, ErrType
	}
	return f, nil
}

// renameExclusive commits from one already opened directory to another with
// macOS RENAME_EXCL semantics. No destination may be overwritten, even when
// an external process races us with a file or empty directory.
func (s *Store) renameExclusive(from, to string) error {
	src, err := s.openDirNoFollow(path.Dir(from))
	if err != nil {
		return err
	}
	defer src.Close()
	dst, err := s.openDirNoFollow(path.Dir(to))
	if err != nil {
		return err
	}
	defer dst.Close()
	err = unix.RenameatxNp(int(src.Fd()), path.Base(from),
		int(dst.Fd()), path.Base(to), unix.RENAME_EXCL)
	if errors.Is(err, fs.ErrExist) {
		return ErrExists
	}
	return err
}
