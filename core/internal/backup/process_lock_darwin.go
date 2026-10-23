//go:build darwin

package backup

import (
	"errors"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

var ErrAppRunning = errors.New("LightIsle application or another recovery process is already using this data directory")

// LockDataDir coordinates the live Core with privileged offline metadata
// recovery. A stale file is harmless: the kernel releases flock on crash.
func LockDataDir(dataDir string) (*os.File, error) {
	if err := os.MkdirAll(dataDir, 0700); err != nil {
		return nil, err
	}
	name := filepath.Join(dataDir, ".lightisle-process.lock")
	fd, err := unix.Open(name, unix.O_RDWR|unix.O_CREAT|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), name)
	if err = unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		file.Close()
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, ErrAppRunning
		}
		return nil, err
	}
	return file, nil
}

// MetadataActivationPending means the metadata files may be a mixed
// generation. Core must refuse to serve until the owner repairs this journal.
func MetadataActivationPending(dataDir string) bool {
	return recoveryFileExists(dataDir, ".lightisle-offline-restore.json")
}

// SessionCleanupPending marks credentials that still need revocation after an
// activation or rollback. Core must try to finalize this before opening its
// listener; a damaged accounts database must still be recoverable offline.
func SessionCleanupPending(dataDir string) bool {
	return recoveryFileExists(dataDir, revokeRecoverySessionsName)
}

// RecoveryPending reports either durable recovery condition to owner-facing
// inspection and diagnostics. Core startup uses MetadataActivationPending so
// a session-cleanup marker is finalized rather than blocking its retry.
func RecoveryPending(dataDir string) bool {
	return MetadataActivationPending(dataDir) || SessionCleanupPending(dataDir)
}

func recoveryFileExists(dataDir, name string) bool {
	_, err := os.Lstat(filepath.Join(dataDir, name))
	return err == nil
}
