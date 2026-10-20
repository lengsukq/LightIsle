//go:build darwin

package files

import (
	"errors"
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

// ErrSyncUnsupported reports that the filesystem refused F_FULLFSYNC. The
// caller must surface this as a failed durable write; falling back to fsync
// would keep the data in the drive's volatile cache and silently weaken the
// power-loss guarantee.
var ErrSyncUnsupported = errors.New("full_fsync_unsupported")

// syncStorage flushes a regular file with F_FULLFSYNC, which on macOS combines
// fsync(2) with a flush of the drive's own cache. Plain fsync alone does not
// guarantee survival of a power loss on Apple hardware. Only errors that mean
// "this filesystem has no such operation" are mapped to ErrSyncUnsupported;
// every other error is returned unchanged.
func syncStorage(f *os.File) error {
	for {
		_, err := unix.FcntlInt(f.Fd(), unix.F_FULLFSYNC, 0)
		if err == nil {
			return nil
		}
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if errors.Is(err, unix.ENOTSUP) || errors.Is(err, unix.EINVAL) || errors.Is(err, unix.ENOTTY) {
			return fmt.Errorf("%w: %v", ErrSyncUnsupported, err)
		}
		return err
	}
}

// syncDirectoryStorage makes directory entry changes durable with fsync(2).
// F_FULLFSYNC is deliberately not used here: its contract is aimed at file
// data and some filesystems reject it on directory descriptors. fsync on a
// directory is the supported barrier for renames, links and unlinks, and any
// error is returned rather than treated as a successful publication.
func syncDirectoryStorage(f *os.File) error {
	for {
		err := f.Sync()
		if !errors.Is(err, unix.EINTR) {
			return err
		}
	}
}
