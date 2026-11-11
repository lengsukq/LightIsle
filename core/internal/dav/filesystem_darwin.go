//go:build darwin

package dav

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log/slog"
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

func newDAVSwapName(destinationDir int) (string, error) {
	var raw [8]byte
	for attempt := 0; attempt < 8; attempt++ {
		if _, err := rand.Read(raw[:]); err != nil {
			return "", err
		}
		candidate := ".dav-swap-" + hex.EncodeToString(raw[:])
		var st unix.Stat_t
		err := unix.Fstatat(destinationDir, candidate, &st, unix.AT_SYMLINK_NOFOLLOW)
		if errors.Is(err, os.ErrNotExist) || errors.Is(err, unix.ENOENT) {
			return candidate, nil
		}
		if err != nil {
			return "", err
		}
	}
	return "", os.ErrExist
}

func renameExchange(sourceDir int, sourceName string, destinationDir int, destinationName string) error {
	err := unix.RenameatxNp(sourceDir, sourceName, destinationDir, destinationName, unix.RENAME_SWAP)
	if errors.Is(err, unix.ENOTSUP) || errors.Is(err, unix.EOPNOTSUPP) {
		swapName, nameErr := newDAVSwapName(destinationDir)
		if nameErr != nil {
			return nameErr
		}
		if err := unix.Renameat(destinationDir, destinationName, destinationDir, swapName); err != nil {
			return err
		}
		if err := unix.Renameat(sourceDir, sourceName, destinationDir, destinationName); err != nil {
			if rbErr := unix.Renameat(destinationDir, swapName, destinationDir, destinationName); rbErr != nil {
				slog.Error("dav swap fallback rollback failed", "swapName", swapName, "destination", destinationName, "error", rbErr)
				return errors.Join(err, rbErr)
			}
			return err
		}
		if err := unix.Renameat(destinationDir, swapName, sourceDir, sourceName); err != nil {
			rbErr1 := unix.Renameat(destinationDir, destinationName, sourceDir, sourceName)
			rbErr2 := unix.Renameat(destinationDir, swapName, destinationDir, destinationName)
			if rbErr := errors.Join(rbErr1, rbErr2); rbErr != nil {
				slog.Error("dav swap fallback rollback failed", "swapName", swapName, "source", sourceName, "destination", destinationName, "error", rbErr)
				return errors.Join(err, rbErr)
			}
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
