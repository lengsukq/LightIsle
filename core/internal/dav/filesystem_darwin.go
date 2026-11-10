//go:build darwin

package dav

import (
	"errors"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

func fileIdentity(info os.FileInfo) (dev, ino uint64, ctimeSec, ctimeNsec int64, ok bool) {
	if info == nil {
		return
	}
	switch stat := info.Sys().(type) {
	case *unix.Stat_t:
		return uint64(stat.Dev), stat.Ino, stat.Ctim.Sec, stat.Ctim.Nsec, stat.Ino != 0
	case *syscall.Stat_t:
		return uint64(stat.Dev), stat.Ino, stat.Ctimespec.Sec, stat.Ctimespec.Nsec, stat.Ino != 0
	}
	return
}

func renameNoReplace(sourceDir int, sourceName string, destinationDir int, destinationName string) error {
	err := unix.RenameatxNp(sourceDir, sourceName, destinationDir, destinationName, unix.RENAME_EXCL)
	if errors.Is(err, unix.ENOTSUP) || errors.Is(err, unix.EOPNOTSUPP) {
		var dstStat unix.Stat_t
		if statErr := unix.Fstatat(destinationDir, destinationName, &dstStat, unix.AT_SYMLINK_NOFOLLOW); statErr == nil {
			return os.ErrExist
		} else if !errors.Is(statErr, os.ErrNotExist) {
			return statErr
		}
		return unix.Renameat(sourceDir, sourceName, destinationDir, destinationName)
	}
	return err
}

func renameExchange(sourceDir int, sourceName string, destinationDir int, destinationName string) error {
	err := unix.RenameatxNp(sourceDir, sourceName, destinationDir, destinationName, unix.RENAME_SWAP)
	if errors.Is(err, unix.ENOTSUP) || errors.Is(err, unix.EOPNOTSUPP) {
		swapName := ".dav-swap-" + sourceName
		_ = unix.Unlinkat(destinationDir, swapName, 0)
		if err := unix.Renameat(destinationDir, destinationName, destinationDir, swapName); err != nil {
			return err
		}
		if err := unix.Renameat(sourceDir, sourceName, destinationDir, destinationName); err != nil {
			_ = unix.Renameat(destinationDir, swapName, destinationDir, destinationName)
			return err
		}
		if err := unix.Renameat(destinationDir, swapName, sourceDir, sourceName); err != nil {
			_ = unix.Renameat(destinationDir, destinationName, sourceDir, sourceName)
			_ = unix.Renameat(destinationDir, swapName, destinationDir, destinationName)
			return err
		}
		return nil
	}
	return err
}

func syncRegular(file *os.File) error {
	for {
		_, err := unix.FcntlInt(file.Fd(), unix.F_FULLFSYNC, 0)
		if !errors.Is(err, unix.EINTR) {
			return err
		}
	}
}
