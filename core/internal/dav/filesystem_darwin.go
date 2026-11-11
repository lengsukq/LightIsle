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
	return unix.RenameatxNp(sourceDir, sourceName, destinationDir, destinationName, unix.RENAME_EXCL)
}

func renameExchange(sourceDir int, sourceName string, destinationDir int, destinationName string) error {
	return unix.RenameatxNp(sourceDir, sourceName, destinationDir, destinationName, unix.RENAME_SWAP)
}

func syncRegular(file *os.File) error {
	for {
		_, err := unix.FcntlInt(file.Fd(), unix.F_FULLFSYNC, 0)
		if !errors.Is(err, unix.EINTR) {
			return err
		}
	}
}
