//go:build darwin || linux

package dav

import (
	"errors"
	"io/fs"
	"os"
	"path"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

func openRootDirectory(name string) (*os.File, error) {
	fd, err := unix.Open(name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), name), nil
}

func dupDirectory(file *os.File) (*os.File, error) {
	fd, err := unix.Dup(int(file.Fd()))
	if err != nil {
		return nil, err
	}
	unix.CloseOnExec(fd)
	return os.NewFile(uintptr(fd), file.Name()), nil
}

// openDirectoryNoFollow descends from a pinned root descriptor. Every
// component is opened as a directory with O_NOFOLLOW, so an attacker cannot
// redirect a granted DAV path through a symlink.
func openDirectoryNoFollow(root *os.File, relative string) (*os.File, error) {
	current, err := dupDirectory(root)
	if err != nil {
		return nil, err
	}
	if relative == "." || relative == "" {
		return current, nil
	}
	for _, component := range strings.Split(relative, "/") {
		fd, openErr := unix.Openat(int(current.Fd()), component,
			unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
		if openErr != nil {
			current.Close()
			return nil, openErr
		}
		next := os.NewFile(uintptr(fd), path.Join(current.Name(), component))
		if closeErr := current.Close(); closeErr != nil {
			next.Close()
			return nil, closeErr
		}
		current = next
	}
	return current, nil
}

func openParentNoFollow(root *os.File, name string) (*os.File, string, error) {
	if name == "." || name == "" {
		return nil, "", os.ErrInvalid
	}
	parent, err := openDirectoryNoFollow(root, path.Dir(name))
	if err != nil {
		return nil, "", err
	}
	return parent, path.Base(name), nil
}

func openRegularAt(parent *os.File, name string, flags int, perm os.FileMode) (*os.File, error) {
	fd, err := unix.Openat(int(parent.Fd()), name,
		flags|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, uint32(perm.Perm()))
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path.Join(parent.Name(), name))
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, err
	}
	if !info.Mode().IsRegular() && !info.IsDir() {
		file.Close()
		return nil, os.ErrPermission
	}
	return file, nil
}

func unixOpenAtStage(parent *os.File, name string) (uintptr, error) {
	fd, err := unix.Openat(int(parent.Fd()), name,
		unix.O_RDWR|unix.O_CREAT|unix.O_EXCL|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return 0, err
	}
	return uintptr(fd), nil
}

func statAtNoFollow(parent *os.File, name string) (os.FileInfo, error) {
	var stat unix.Stat_t
	if err := unix.Fstatat(int(parent.Fd()), name, &stat, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return nil, err
	}
	return infoFromStat(name, &stat), nil
}

type unixFileInfo struct {
	name    string
	size    int64
	mode    os.FileMode
	modTime time.Time
	sys     *unix.Stat_t
}

func (i unixFileInfo) Name() string       { return i.name }
func (i unixFileInfo) Size() int64        { return i.size }
func (i unixFileInfo) Mode() os.FileMode  { return i.mode }
func (i unixFileInfo) ModTime() time.Time { return i.modTime }
func (i unixFileInfo) IsDir() bool        { return i.mode.IsDir() }
func (i unixFileInfo) Sys() any           { return i.sys }

func infoFromStat(name string, stat *unix.Stat_t) os.FileInfo {
	mode := os.FileMode(stat.Mode & 0777)
	switch stat.Mode & unix.S_IFMT {
	case unix.S_IFDIR:
		mode |= os.ModeDir
	case unix.S_IFLNK:
		mode |= os.ModeSymlink
	case unix.S_IFIFO:
		mode |= os.ModeNamedPipe
	case unix.S_IFCHR:
		mode |= os.ModeDevice | os.ModeCharDevice
	case unix.S_IFBLK:
		mode |= os.ModeDevice
	case unix.S_IFSOCK:
		mode |= os.ModeSocket
	}
	return unixFileInfo{
		name:    name,
		size:    stat.Size,
		mode:    mode,
		modTime: time.Unix(stat.Mtim.Sec, stat.Mtim.Nsec),
		sys:     stat,
	}
}

func sameFileVersion(a, b os.FileInfo) bool {
	if a == nil || b == nil || a.Mode() != b.Mode() ||
		a.Size() != b.Size() || !a.ModTime().Equal(b.ModTime()) {
		return false
	}
	firstDev, firstIno, firstCTime, firstNS, firstOK := fileIdentity(a)
	secondDev, secondIno, secondCTime, secondNS, secondOK := fileIdentity(b)
	return firstOK && secondOK && firstDev == secondDev && firstIno == secondIno &&
		firstCTime == secondCTime && firstNS == secondNS
}

// sameFileContentVersion ignores ctime because rename-exchange may update an
// inode's metadata timestamp even though its contents and identity are intact.
func sameFileContentVersion(a, b os.FileInfo) bool {
	return a != nil && b != nil && sameIdentity(a, b) && a.Mode() == b.Mode() &&
		a.Size() == b.Size() && a.ModTime().Equal(b.ModTime())
}

func sameIdentity(a, b os.FileInfo) bool {
	firstDev, firstIno, _, _, firstOK := fileIdentity(a)
	secondDev, secondIno, _, _, secondOK := fileIdentity(b)
	return firstOK && secondOK && firstDev == secondDev && firstIno == secondIno
}

func sameDirectory(root *os.File, relative string, expected os.FileInfo) bool {
	dir, err := openDirectoryNoFollow(root, relative)
	if err != nil {
		return false
	}
	defer dir.Close()
	actual, err := dir.Stat()
	return err == nil && sameIdentity(expected, actual)
}

func mkdirAt(parent *os.File, name string, perm os.FileMode) error {
	return unix.Mkdirat(int(parent.Fd()), name, uint32(perm.Perm()))
}

func unlinkAt(parent *os.File, name string, directory bool) error {
	flags := 0
	if directory {
		flags = unix.AT_REMOVEDIR
	}
	err := unix.Unlinkat(int(parent.Fd()), name, flags)
	if errors.Is(err, fs.ErrNotExist) {
		return fs.ErrNotExist
	}
	return err
}

func renameAtNoReplace(sourceDir *os.File, sourceName string, destinationDir *os.File, destinationName string) error {
	return renameNoReplace(int(sourceDir.Fd()), sourceName, int(destinationDir.Fd()), destinationName)
}

func exchangeAt(sourceDir *os.File, sourceName string, destinationDir *os.File, destinationName string) error {
	return renameExchange(int(sourceDir.Fd()), sourceName, int(destinationDir.Fd()), destinationName)
}

func syncDirectory(file *os.File) error {
	for {
		err := file.Sync()
		if !errors.Is(err, unix.EINTR) {
			return err
		}
	}
}

func freeBytes(file *os.File) (uint64, error) {
	var stat unix.Statfs_t
	if err := unix.Fstatfs(int(file.Fd()), &stat); err != nil {
		return 0, err
	}
	return uint64(stat.Bavail) * uint64(stat.Bsize), nil
}
