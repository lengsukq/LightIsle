//go:build darwin

package files

import (
	"errors"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

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

// statEntryNoFollow inspects a single entry relative to a held directory
// descriptor without following symlinks and without opening the entry.
// Opening with O_RDONLY would fail for an unreadable regular file, which must
// still be listable; only the directory needs to be searchable. Metadata is
// read with fstatat(AT_SYMLINK_NOFOLLOW), so a symlink, socket, device or fifo
// is classified from its own inode and reported as unsupported.
func statEntryNoFollow(dir *os.File, name string) (os.FileInfo, error) {
	var stat unix.Stat_t
	if err := unix.Fstatat(int(dir.Fd()), name, &stat, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return nil, err
	}
	info := &statFileInfo{
		name:    name,
		mode:    fileModeFromStat(stat.Mode),
		size:    stat.Size,
		modTime: time.Unix(stat.Mtim.Sec, stat.Mtim.Nsec),
		sys:     stat,
	}
	if !info.Mode().IsRegular() && !info.IsDir() {
		return nil, ErrType
	}
	return info, nil
}

// statFileInfo mirrors the os package's Darwin conversion of struct stat so
// callers observe the same Mode, Size and ModTime as os.FileInfo.
type statFileInfo struct {
	name    string
	mode    os.FileMode
	size    int64
	modTime time.Time
	sys     unix.Stat_t
}

func (f *statFileInfo) Name() string       { return f.name }
func (f *statFileInfo) Size() int64        { return f.size }
func (f *statFileInfo) Mode() os.FileMode  { return f.mode }
func (f *statFileInfo) ModTime() time.Time { return f.modTime }
func (f *statFileInfo) IsDir() bool        { return f.mode.IsDir() }
func (f *statFileInfo) Sys() any           { return &f.sys }

func fileModeFromStat(mode uint16) os.FileMode {
	out := os.FileMode(mode & 0777)
	switch mode & unix.S_IFMT {
	case unix.S_IFBLK, unix.S_IFWHT:
		out |= os.ModeDevice
	case unix.S_IFCHR:
		out |= os.ModeDevice | os.ModeCharDevice
	case unix.S_IFDIR:
		out |= os.ModeDir
	case unix.S_IFIFO:
		out |= os.ModeNamedPipe
	case unix.S_IFLNK:
		out |= os.ModeSymlink
	case unix.S_IFSOCK:
		out |= os.ModeSocket
	}
	if mode&unix.S_ISGID != 0 {
		out |= os.ModeSetgid
	}
	if mode&unix.S_ISUID != 0 {
		out |= os.ModeSetuid
	}
	if mode&unix.S_ISVTX != 0 {
		out |= os.ModeSticky
	}
	return out
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
