// Package computerfiles provides read-only, descriptor-relative host access.
package computerfiles

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

var ErrPath = errors.New("computer_path_invalid")
var ErrChanged = errors.New("computer_folder_changed")

func openComponent(fd int, name string, directory bool) (int, error) {
	var before unix.Stat_t
	if err := unix.Fstatat(fd, name, &before, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return -1, err
	}
	kind := before.Mode & unix.S_IFMT
	if (directory && kind != unix.S_IFDIR) || (!directory && kind != unix.S_IFDIR && kind != unix.S_IFREG) {
		return -1, ErrPath
	}
	flags := unix.O_RDONLY | unix.O_CLOEXEC | unix.O_NOFOLLOW | unix.O_NONBLOCK
	if directory || kind == unix.S_IFDIR {
		flags |= unix.O_DIRECTORY
	}
	next, err := unix.Openat(fd, name, flags, 0)
	if err != nil {
		return -1, err
	}
	var after unix.Stat_t
	if err := unix.Fstat(next, &after); err != nil || before.Dev != after.Dev || before.Ino != after.Ino || before.Mode&unix.S_IFMT != after.Mode&unix.S_IFMT {
		unix.Close(next)
		return -1, ErrChanged
	}
	return next, nil
}

// Clean rejects ambiguous paths instead of normalising away traversal.
func Clean(path string) (string, error) {
	if path == "" || !filepath.IsAbs(path) || strings.IndexByte(path, 0) >= 0 {
		return "", ErrPath
	}
	for _, part := range strings.Split(path, "/") {
		if part == "." || part == ".." {
			return "", ErrPath
		}
	}
	return filepath.Clean(path), nil
}

// Open opens every component without following symlinks. A final O_NONBLOCK
// prevents special files from blocking; callers must check the returned type.
func Open(path string) (*os.File, error) {
	clean, err := Clean(path)
	if err != nil {
		return nil, err
	}
	fd, err := unix.Open("/", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	parts := strings.Split(strings.TrimPrefix(clean, "/"), "/")
	for i, part := range parts {
		if part == "" {
			continue
		}
		next, openErr := openComponent(fd, part, i != len(parts)-1)
		unix.Close(fd)
		if openErr != nil {
			return nil, openErr
		}
		fd = next
	}
	return os.NewFile(uintptr(fd), clean), nil
}

func Identity(f *os.File) (string, error) {
	var st unix.Stat_t
	if err := unix.Fstat(int(f.Fd()), &st); err != nil {
		return "", err
	}
	if st.Mode&unix.S_IFMT != unix.S_IFDIR {
		return "", ErrPath
	}
	return fmt.Sprintf("%d:%d", st.Dev, st.Ino), nil
}

// OpenInGrant pins and checks the granted directory before walking down from
// its descriptor. A swapped mount or directory cannot inherit the grant.
func OpenInGrant(base, identity, requested string) (*os.File, error) {
	base, err := Clean(base)
	if err != nil {
		return nil, err
	}
	requested, err = Clean(requested)
	if err != nil {
		return nil, err
	}
	rel, err := filepath.Rel(base, requested)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return nil, ErrPath
	}
	root, err := Open(base)
	if err != nil {
		return nil, err
	}
	actual, err := Identity(root)
	if err != nil || actual != identity {
		root.Close()
		return nil, ErrChanged
	}
	if rel == "." {
		return root, nil
	}
	var baseStat unix.Stat_t
	if err := unix.Fstat(int(root.Fd()), &baseStat); err != nil {
		root.Close()
		return nil, err
	}
	fd := int(root.Fd())
	parts := strings.Split(rel, string(filepath.Separator))
	for i, part := range parts {
		next, openErr := openComponent(fd, part, i != len(parts)-1)
		root.Close()
		if openErr != nil {
			return nil, openErr
		}
		var childStat unix.Stat_t
		if statErr := unix.Fstat(next, &childStat); statErr != nil || childStat.Dev != baseStat.Dev {
			unix.Close(next)
			return nil, ErrChanged
		}
		root = os.NewFile(uintptr(next), requested)
		fd = next
	}
	return root, nil
}

func IsRegular(info fs.FileInfo) bool { return info.Mode().IsRegular() }
