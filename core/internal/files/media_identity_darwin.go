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
	return objectIdentity(info, true)
}

// trashObjectIdentity also accepts directories, whose inode identity is
// needed to distinguish a trashed folder from a later same-name replacement.
func trashObjectIdentity(info os.FileInfo) string {
	if info == nil || (!info.Mode().IsRegular() && !info.IsDir()) {
		return ""
	}
	// The enclosing registered root pins the physical volume. Device numbers
	// can change after reconnecting the same disk, so do not persist them as
	// part of a durable trash identity.
	return objectIdentity(info, false)
}

func objectIdentity(info os.FileInfo, includeDevice bool) string {
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
	encoded := fmt.Sprintf("%d:%d:%d:%d", ino, sec, nsec, generation)
	if includeDevice {
		// Preserve the existing media/ledger identity format.
		encoded = fmt.Sprintf("%d:%s", dev, encoded)
	}
	sum := sha256.Sum256([]byte(encoded))
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
