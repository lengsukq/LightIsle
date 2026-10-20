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

// Existing interrupted activation means the SQLite files may be a mixed
// generation. The application must refuse to start until owner-side repair.
func RecoveryPending(dataDir string) bool {
	_, err := os.Lstat(filepath.Join(dataDir, ".lightisle-offline-restore.json"))
	return err == nil
}
