//go:build darwin

package files

import (
	"errors"
	"io/fs"
	"os"
	"path"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

var (
	ErrDAVReplaceUnsupported   = errors.New("dav_replace_unsupported")
	ErrDAVReplacementUncertain = errors.New("dav_replacement_uncertain")
)

func (s *Store) replaceDAVFile(source, target string, sourceInfo, targetInfo os.FileInfo, finish func(string) error) error {
	if _, err := validate(target, false); err != nil || source == target {
		return ErrPath
	}
	// Only this transport's random staging leaf may bypass the reserved
	// name check. Its parent and every normal source still use no-follow FDs.
	if strings.HasPrefix(path.Base(source), ".lightisle-dav-") {
		leaf := strings.TrimPrefix(path.Base(source), ".lightisle-dav-")
		if !trashIDRule.MatchString(leaf) || path.Clean(source) != source {
			return ErrPath
		}
		if _, err := validate(path.Dir(source), true); err != nil {
			return err
		}
	} else if _, err := validate(source, false); err != nil {
		return err
	}
	unlock, err := s.lockTrash()
	if err != nil {
		return err
	}
	defer unlock()
	from, err := s.openDirNoFollow(path.Dir(source))
	if err != nil {
		return err
	}
	defer from.Close()
	to, err := s.openDirNoFollow(path.Dir(target))
	if err != nil {
		return err
	}
	defer to.Close()
	trash, err := s.openTrashDirNoFollow()
	if err != nil {
		return err
	}
	defer trash.Close()
	fromLeaf, toLeaf := path.Base(source), path.Base(target)
	check := func(dir *os.File, name string, expected os.FileInfo) bool {
		info, err := statEntryNoFollow(dir, name)
		identity := trashObjectIdentity(expected)
		return err == nil && identity != "" && trashObjectIdentity(info) == identity &&
			MediaFileHasSingleLink(info) && info.Size() == expected.Size() && info.ModTime().Equal(expected.ModTime())
	}
	attached := func(dir *os.File, relative string) bool {
		actual, err := s.openDirNoFollow(relative)
		if err != nil {
			return false
		}
		defer actual.Close()
		expectedInfo, err := dir.Stat()
		currentInfo, statErr := actual.Stat()
		return err == nil && statErr == nil && os.SameFile(currentInfo, expectedInfo)
	}
	parentsCurrent := func() bool {
		return attached(from, path.Dir(source)) && attached(to, path.Dir(target))
	}
	if !parentsCurrent() || !check(from, fromLeaf, sourceInfo) || !check(to, toLeaf, targetInfo) ||
		trashObjectIdentity(sourceInfo) == trashObjectIdentity(targetInfo) {
		return ErrTrashChanged
	}
	id := randomName()
	if _, err := statEntryNoFollow(trash, id); !errors.Is(err, fs.ErrNotExist) {
		return ErrExists
	}
	entry := TrashEntry{
		ID: id, OriginalPath: target, Name: toLeaf, DeletedAt: time.Now().UTC(),
		ObjectIdentity: trashObjectIdentity(targetInfo),
	}
	if err := s.writeTrashJournalWithRecovery(entry, source); err != nil {
		return err
	}
	if !parentsCurrent() || !check(from, fromLeaf, sourceInfo) || !check(to, toLeaf, targetInfo) {
		_ = s.removeTrashJournal(id)
		return ErrTrashChanged
	}
	swap := unix.RenameatxNp(int(from.Fd()), fromLeaf, int(to.Fd()), toLeaf, unix.RENAME_SWAP)
	if swap != nil {
		_ = s.removeTrashJournal(id)
		if errors.Is(swap, unix.ENOTSUP) || errors.Is(swap, unix.EOPNOTSUPP) || errors.Is(swap, unix.EXDEV) {
			return ErrDAVReplaceUnsupported
		}
		return swap
	}
	// Every error after the exchange retains the original or its journal.
	// Never unlink a path whose identity could have changed concurrently.
	if !parentsCurrent() || !check(from, fromLeaf, targetInfo) || !check(to, toLeaf, sourceInfo) {
		return ErrDAVReplacementUncertain
	}
	if err := unix.RenameatxNp(int(from.Fd()), fromLeaf, int(trash.Fd()), id, unix.RENAME_EXCL); err != nil {
		return errors.Join(ErrDAVReplacementUncertain, err)
	}
	if !parentsCurrent() || !check(trash, id, targetInfo) || !check(to, toLeaf, sourceInfo) {
		return ErrDAVReplacementUncertain
	}
	for _, directory := range []*os.File{from, to, trash} {
		if err := s.syncDirContents(directory); err != nil {
			return errors.Join(ErrDAVReplacementUncertain, err)
		}
	}
	if finish != nil {
		if err := finish(id); err != nil {
			return errors.Join(ErrDAVReplacementUncertain, err)
		}
	}
	return nil
}

func (s *Store) undoUnexpectedDAVTrash(entry TrashEntry, moved string) error {
	trash, err := s.openTrashDirNoFollow()
	if err != nil {
		return err
	}
	defer trash.Close()
	parent, err := s.openDirNoFollow(path.Dir(entry.OriginalPath))
	if err != nil {
		return err
	}
	defer parent.Close()
	if err := renameAtStrictNoReplace(int(trash.Fd()), entry.ID, int(parent.Fd()), path.Base(entry.OriginalPath)); err != nil {
		return err
	}
	if err := s.syncRename(moved, entry.OriginalPath); err != nil {
		return err
	}
	return s.removeTrashJournal(entry.ID)
}
