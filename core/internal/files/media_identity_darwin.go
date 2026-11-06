//go:build darwin

package files

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

// MediaFileIdentity identifies an inode on the verified volume without
// exposing filesystem identifiers through the HTTP API. Missing birth time
// means identity cannot be verified and must never imply a match.
func MediaFileIdentity(info os.FileInfo) string {
	if info == nil || !info.Mode().IsRegular() {
		return ""
	}
	var dev, ino, generation uint64
	var sec, nsec int64
	switch stat := info.Sys().(type) {
	case *unix.Stat_t:
		dev, ino, generation = uint64(stat.Dev), stat.Ino, uint64(stat.Gen)
		sec, nsec = stat.Btim.Sec, stat.Btim.Nsec
	case *syscall.Stat_t:
		dev, ino, generation = uint64(stat.Dev), stat.Ino, uint64(stat.Gen)
		sec, nsec = stat.Birthtimespec.Sec, stat.Birthtimespec.Nsec
	default:
		return ""
	}
	if ino == 0 || sec <= 0 || nsec < 0 || nsec >= 1_000_000_000 {
		return ""
	}
	sum := sha256.Sum256([]byte(fmt.Sprintf("%d:%d:%d:%d:%d", dev, ino, sec, nsec, generation)))
	return hex.EncodeToString(sum[:])
}

func MediaFileHasSingleLink(info os.FileInfo) bool {
	if info == nil || !info.Mode().IsRegular() {
		return false
	}
	switch stat := info.Sys().(type) {
	case *unix.Stat_t:
		return stat.Nlink == 1
	case *syscall.Stat_t:
		return stat.Nlink == 1
	default:
		return false
	}
}
