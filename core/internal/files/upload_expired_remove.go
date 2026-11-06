package files

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
)

// removeExpiredUploadFiles moves both names to unpredictable private staging
// names before unlinking them. If a path was replaced after inventory, the
// moved inode does not match and is restored without overwriting anything.
// Any failed rollback remains visible as an unrecognized staging entry.
func (s *Store) removeExpiredUploadFiles(root *os.Root, dir *os.File, record UploadRecord) error {
	if root == nil || dir == nil || record.partInfo == nil || record.journalInfo == nil {
		return ErrUploadCorrupt
	}
	id := record.State.ID
	if !uploadIDPattern.MatchString(id) {
		return ErrPath
	}
	if s.beforeUploadRemoval != nil {
		s.beforeUploadRemoval()
	}
	partName, journalName := id+".part", id+".json"
	temporary := ".cleanup-" + randomName()
	partTemp, journalTemp := temporary+".part", temporary+".json"
	fd := int(dir.Fd())
	partMoved, journalMoved := false, false
	rollback := func(cause error) error {
		if journalMoved {
			if err := renameAtNoReplace(fd, journalTemp, fd, journalName); err != nil {
				cause = errors.Join(cause, fmt.Errorf("cleanup_journal_retained: %w", err))
			}
		}
		if partMoved {
			if err := renameAtNoReplace(fd, partTemp, fd, partName); err != nil {
				cause = errors.Join(cause, fmt.Errorf("cleanup_part_retained: %w", err))
			}
		}
		if err := syncUploadsRoot(s, root); err != nil {
			cause = errors.Join(cause, err)
		}
		return cause
	}
	if err := renameAtNoReplace(fd, partName, fd, partTemp); err != nil {
		return err
	}
	partMoved = true
	if err := syncUploadsRoot(s, root); err != nil {
		return rollback(err)
	}
	partInfo, err := root.Lstat(partTemp)
	if err != nil || !sameExpiredUploadFile(record.partInfo, partInfo) || validatePrivateUploadPart(partInfo) != nil {
		return rollback(ErrUploadCorrupt)
	}
	if err := renameAtNoReplace(fd, journalName, fd, journalTemp); err != nil {
		return rollback(err)
	}
	journalMoved = true
	if err := syncUploadsRoot(s, root); err != nil {
		return rollback(err)
	}
	journalInfo, err := root.Lstat(journalTemp)
	if err != nil || !sameExpiredUploadFile(record.journalInfo, journalInfo) {
		return rollback(ErrUploadCorrupt)
	}
	// If the staging directory or destination changed after inventory, leave
	// both pieces recoverable. The destination must still be absent.
	if _, _, err := s.openExistingUploadsRoot(); err != nil {
		return rollback(err)
	}
	target, err := s.safePath(record.State.Path, false, true)
	if err != nil {
		return rollback(err)
	}
	if _, err := s.root.Lstat(target); !errors.Is(err, fs.ErrNotExist) {
		return rollback(ErrUploadCorrupt)
	}
	partInfo, partErr := root.Lstat(partTemp)
	journalInfo, journalErr := root.Lstat(journalTemp)
	if partErr != nil || journalErr != nil || !sameExpiredUploadFile(record.partInfo, partInfo) ||
		!sameExpiredUploadFile(record.journalInfo, journalInfo) || validatePrivateUploadPart(partInfo) != nil {
		return rollback(ErrUploadCorrupt)
	}
	if err := root.Remove(partTemp); err != nil {
		return rollback(err)
	}
	partMoved = false
	if err := syncUploadsRoot(s, root); err != nil {
		return err
	}
	if err := root.Remove(journalTemp); err != nil {
		return err
	}
	return syncUploadsRoot(s, root)
}

func sameExpiredUploadFile(expected, actual os.FileInfo) bool {
	return expected != nil && actual != nil && expected.Mode().IsRegular() && actual.Mode().IsRegular() &&
		os.SameFile(expected, actual) && expected.Size() == actual.Size() && expected.ModTime().Equal(actual.ModTime())
}
