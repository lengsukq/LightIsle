//go:build linux

package dav

import (
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
		return stat.Dev, stat.Ino, stat.Ctim.Sec, stat.Ctim.Nsec, stat.Ino != 0
	case *syscall.Stat_t:
		return stat.Dev, stat.Ino, stat.Ctim.Sec, stat.Ctim.Nsec, stat.Ino != 0
	}
	return
}

func renameNoReplace(sourceDir int, sourceName string, destinationDir int, destinationName string) error {
	return unix.Renameat2(sourceDir, sourceName, destinationDir, destinationName, unix.RENAME_NOREPLACE)
}

func renameExchange(sourceDir int, sourceName string, destinationDir int, destinationName string) error {
	return unix.Renameat2(sourceDir, sourceName, destinationDir, destinationName, unix.RENAME_EXCHANGE)
}

func syncRegular(file *os.File) error {
	return file.Sync()
}
