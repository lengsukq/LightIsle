//go:build darwin

package backup

import (
	"errors"
	"os"
	"path"

	"golang.org/x/sys/unix"
)

func retentionRenameNoReplace(root *os.Root, oldName, newName string) error {
	if !retentionLeafName(oldName) || !retentionLeafName(newName) {
		return ErrInvalid
	}
	directory, err := root.Open(".")
	if err != nil {
		return err
	}
	defer directory.Close()
	fd := int(directory.Fd())
	err = unix.RenameatxNp(fd, oldName, fd, newName, unix.RENAME_EXCL)
	if errors.Is(err, unix.ENOTSUP) || errors.Is(err, unix.EOPNOTSUPP) {
		var dstStat unix.Stat_t
		if statErr := unix.Fstatat(fd, newName, &dstStat, unix.AT_SYMLINK_NOFOLLOW); statErr == nil {
			return unix.EEXIST
		} else if !errors.Is(statErr, os.ErrNotExist) {
			return statErr
		}
		return unix.Renameat(fd, oldName, fd, newName)
	}
	return err
}

func retentionLeafName(name string) bool {
	return name != "" && name != "." && name != ".." && path.Base(name) == name
}
