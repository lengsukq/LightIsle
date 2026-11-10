//go:build darwin

package files

import (
	"os"
	"path"

	"golang.org/x/sys/unix"
)

// cloneRegularToStage attempts an atomic APFS copy-on-write clone (clonefileat)
// from src into the private staging name tmp within the same store root. When
// the filesystem does not support clonefileat (e.g. ExFAT/SMB) or the source
// changes concurrently, it cleans up tmp and returns (nil, false) so the caller
// falls back transparently to copyVerified.
func (s *Store) cloneRegularToStage(src, tmp string, expected os.FileInfo) (*os.File, bool) {
	if expected == nil || !expected.Mode().IsRegular() {
		return nil, false
	}
	srcDir, err := s.openDirNoFollow(path.Dir(src))
	if err != nil {
		return nil, false
	}
	defer srcDir.Close()
	dstDir, err := s.openDirNoFollow(path.Dir(tmp))
	if err != nil {
		return nil, false
	}
	defer dstDir.Close()
	srcBase := path.Base(src)
	tmpBase := path.Base(tmp)
	if err := unix.Clonefileat(int(srcDir.Fd()), srcBase, int(dstDir.Fd()), tmpBase, unix.CLONE_NOFOLLOW); err != nil {
		return nil, false
	}
	_ = unix.Fchmodat(int(dstDir.Fd()), tmpBase, 0600, unix.AT_SYMLINK_NOFOLLOW)
	srcAfter, err := statEntryNoFollow(srcDir, srcBase)
	if err != nil || !os.SameFile(expected, srcAfter) || !expected.ModTime().Equal(srcAfter.ModTime()) || expected.Size() != srcAfter.Size() {
		_ = s.root.Remove(tmp)
		return nil, false
	}
	out, err := s.root.OpenFile(tmp, os.O_RDWR, 0600)
	if err != nil {
		_ = s.root.Remove(tmp)
		return nil, false
	}
	stagedInfo, err := out.Stat()
	if err != nil || !stagedInfo.Mode().IsRegular() || stagedInfo.Size() != expected.Size() || !MediaFileHasSingleLink(stagedInfo) {
		_ = out.Close()
		_ = s.root.Remove(tmp)
		return nil, false
	}
	return out, true
}
