//go:build darwin

package files

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"

	"golang.org/x/sys/unix"
)

// ErrModifiedConflict indicates that an optimistic mtime lock failed because
// the target file was modified concurrently on disk (e.g. via Finder or another
// device).
var ErrModifiedConflict = errors.New("file_modified_conflict")

// TextSaveResult captures the durable post-write metadata of an atomic text
// save so HTTP handlers can settle personal quota accounting and return the new
// optimistic-lock token to the client.
type TextSaveResult struct {
	Info     os.FileInfo
	Identity string
}

// ReplaceTextFile atomically replaces (or creates when create is true) a
// regular text file under opMu using a same-directory O_NOFOLLOW temp file,
// fsync, optimistic mtime verification, atomic rename, and directory sync.
// If expectedMtimeUnixNano > 0 and the target file's ModTime().UnixNano() does
// not match, ErrModifiedConflict is returned alongside the current FileInfo.
func (m *Manager) ReplaceTextFile(raw string, content []byte, expectedMtimeUnixNano int64, create bool) (TextSaveResult, error) {
	m.opMu.Lock()
	defer m.opMu.Unlock()
	var res TextSaveResult
	err := m.withRead(func(s *Store) (e error) {
		res, e = s.ReplaceTextFile(raw, content, expectedMtimeUnixNano, create)
		return e
	})
	return res, err
}

func (s *Store) ReplaceTextFile(raw string, content []byte, expectedMtimeUnixNano int64, create bool) (TextSaveResult, error) {
	name, err := s.safePath(raw, false, create)
	if err != nil {
		return TextSaveResult{}, err
	}
	parent := path.Dir(name)
	leaf := path.Base(name)
	dir, err := s.openDirNoFollow(parent)
	if err != nil {
		return TextSaveResult{}, err
	}
	defer dir.Close()
	parentInfo, err := dir.Stat()
	if err != nil {
		return TextSaveResult{}, err
	}
	fd := int(dir.Fd())

	existingInfo, statErr := statEntryNoFollow(dir, leaf)
	existed := statErr == nil
	if statErr != nil && !errors.Is(statErr, fs.ErrNotExist) {
		return TextSaveResult{}, statErr
	}
	if !existed && !create {
		return TextSaveResult{}, fs.ErrNotExist
	}
	if existed {
		if !existingInfo.Mode().IsRegular() {
			return TextSaveResult{}, ErrType
		}
		if create && expectedMtimeUnixNano == 0 {
			return TextSaveResult{Info: existingInfo}, ErrExists
		}
		if expectedMtimeUnixNano > 0 && existingInfo.ModTime().UnixNano() != expectedMtimeUnixNano {
			return TextSaveResult{Info: existingInfo}, ErrModifiedConflict
		}
	}

	parentCurrent := func() bool {
		current, openErr := s.openDirNoFollow(parent)
		if openErr != nil {
			return false
		}
		defer current.Close()
		info, stErr := current.Stat()
		return stErr == nil && os.SameFile(parentInfo, info)
	}

	mode := os.FileMode(0600)
	if existed {
		if m := existingInfo.Mode().Perm(); m != 0 {
			mode = m
		}
	}

	tmp := ".lightisle-text-" + randomName()
	stageFD, err := unix.Openat(fd, tmp, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, uint32(mode))
	if err != nil {
		return TextSaveResult{}, err
	}
	f := os.NewFile(uintptr(stageFD), path.Join(dir.Name(), tmp))
	var stageStat unix.Stat_t
	if err := unix.Fstat(stageFD, &stageStat); err != nil {
		_ = f.Close()
		_ = unix.Unlinkat(fd, tmp, 0)
		return TextSaveResult{}, err
	}
	sameStage := func(entryName string) bool {
		var st unix.Stat_t
		return unix.Fstat(stageFD, &stageStat) == nil &&
			unix.Fstatat(fd, entryName, &st, unix.AT_SYMLINK_NOFOLLOW) == nil &&
			st.Dev == stageStat.Dev && st.Ino == stageStat.Ino
	}
	committed := false
	defer func() {
		_ = f.Close()
		if !committed && sameStage(tmp) {
			_ = unix.Unlinkat(fd, tmp, 0)
		}
	}()

	written := 0
	for written < len(content) {
		n, writeErr := f.Write(content[written:])
		written += n
		if writeErr != nil {
			return TextSaveResult{}, writeErr
		}
		if n == 0 {
			return TextSaveResult{}, io.ErrShortWrite
		}
	}
	if err := s.syncFileContents(f); err != nil {
		return TextSaveResult{}, err
	}
	if !parentCurrent() || !sameStage(tmp) {
		return TextSaveResult{}, ErrPath
	}

	// Re-check target right before atomic publish to catch concurrent local edits.
	latestInfo, latestErr := statEntryNoFollow(dir, leaf)
	if existed {
		if latestErr != nil {
			return TextSaveResult{}, latestErr
		}
		if !latestInfo.Mode().IsRegular() {
			return TextSaveResult{}, ErrType
		}
		if expectedMtimeUnixNano > 0 && latestInfo.ModTime().UnixNano() != expectedMtimeUnixNano {
			return TextSaveResult{Info: latestInfo}, ErrModifiedConflict
		}
		if latestInfo.ModTime().UnixNano() != existingInfo.ModTime().UnixNano() || latestInfo.Size() != existingInfo.Size() {
			return TextSaveResult{Info: latestInfo}, ErrModifiedConflict
		}
		if err := unix.Renameat(fd, tmp, fd, leaf); err != nil {
			return TextSaveResult{}, err
		}
	} else {
		if err := renameAtNoReplace(fd, tmp, fd, leaf); err != nil {
			return TextSaveResult{}, err
		}
	}
	committed = true

	if !parentCurrent() || !sameStage(leaf) {
		return TextSaveResult{}, fmt.Errorf("%w: target changed after text save", ErrPublishedSync)
	}
	if err := s.syncDirContents(dir); err != nil {
		return TextSaveResult{}, fmt.Errorf("%w: %v", ErrPublishedSync, err)
	}
	finalInfo, err := f.Stat()
	if err != nil {
		return TextSaveResult{}, fmt.Errorf("%w: %v", ErrPublishedSync, err)
	}
	var identity string
	if MediaFileHasSingleLink(finalInfo) {
		identity = MediaFileIdentity(finalInfo)
	}
	return TextSaveResult{Info: finalInfo, Identity: identity}, nil
}
