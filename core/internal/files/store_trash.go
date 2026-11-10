package files

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"regexp"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

var trashIDRule = regexp.MustCompile(`^[0-9a-f]{32}$`)

type TrashEntry struct {
	ID           string    `json:"id"`
	OriginalPath string    `json:"originalPath"`
	Name         string    `json:"name"`
	DeletedAt    time.Time `json:"deletedAt"`
	// ObjectIdentity is persisted in the private journal only, not returned
	// in the public trash listing. Older journals legitimately have no identity.
	ObjectIdentity string `json:"-"`
}

type trashJournal struct {
	TrashEntry
	ObjectIdentity string `json:"objectIdentity,omitempty"`
}

// readTrashJournal parses one trash journal. Journal files are the only record
// of an item's original location, so a malformed or mismatched journal is a
// path error rather than a partially trusted entry.
func (s *Store) readTrashJournal(id string) (TrashEntry, error) {
	if !trashIDRule.MatchString(id) {
		return TrashEntry{}, ErrPath
	}
	dir, err := s.openTrashDirNoFollow()
	if err != nil {
		return TrashEntry{}, err
	}
	defer dir.Close()
	return readTrashJournalFromDir(dir, id)
}

func readTrashJournalFromDir(dir *os.File, id string) (TrashEntry, error) {
	fd, err := unix.Openat(int(dir.Fd()), id+".json", unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC|unix.O_NONBLOCK, 0)
	if err != nil {
		return TrashEntry{}, err
	}
	f := os.NewFile(uintptr(fd), id+".json")
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return TrashEntry{}, err
	}
	if !info.Mode().IsRegular() || info.Size() > maxTrashJournalBytes {
		return TrashEntry{}, ErrPath
	}
	data, err := io.ReadAll(io.LimitReader(f, maxTrashJournalBytes+1))
	if err != nil {
		return TrashEntry{}, err
	}
	var journal trashJournal
	if len(data) > maxTrashJournalBytes || json.Unmarshal(data, &journal) != nil || journal.ID != id ||
		(journal.ObjectIdentity != "" && (len(journal.ObjectIdentity) != 64 || strings.Trim(journal.ObjectIdentity, "0123456789abcdef") != "")) {
		return TrashEntry{}, ErrPath
	}
	entry := journal.TrashEntry
	entry.ObjectIdentity = journal.ObjectIdentity
	return entry, nil
}

// writeTrashJournal publishes an entry journal durably: its bytes are flushed,
// then the temp name is renamed, then the trash directory entry set is synced.
// Callers must write the journal *before* moving the user's item into the
// trash so an interruption can never leave an unrecorded trashed item.
func (s *Store) writeTrashJournal(entry TrashEntry) error {
	data, err := json.Marshal(trashJournal{TrashEntry: entry, ObjectIdentity: entry.ObjectIdentity})
	if err != nil {
		return err
	}
	tmp := path.Join(Trash, ".lightisle-trashmeta-"+randomName())
	f, err := s.root.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = s.syncFileContents(f)
	}
	closeErr := f.Close()
	if err != nil {
		_ = s.root.Remove(tmp)
		return err
	}
	if closeErr != nil {
		_ = s.root.Remove(tmp)
		return closeErr
	}
	if err := s.renameFile(tmp, path.Join(Trash, entry.ID+".json")); err != nil {
		_ = s.root.Remove(tmp)
		return err
	}
	if err := s.syncTrashDirectory(); err != nil {
		// The journal is visible but may not survive a crash, and the caller is
		// about to abort the move. Drop it so a later restart cannot adopt a
		// half-published record for content that was never trashed.
		_ = s.removeFile(path.Join(Trash, entry.ID+".json"))
		return err
	}
	return nil
}

// removeTrashJournal forgets one trashed item. Callers must already have made
// the removal of its content durable; deleting the journal first could leave
// surviving content with no record of where it belongs.
func (s *Store) removeTrashJournal(id string) error {
	if err := s.removeFile(path.Join(Trash, id+".json")); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return s.syncTrashDirectory()
}

// forEachTrashEntry streams parsed trash journal entries in directory order;
// the callback returns false to stop early. Reads are batched so even an
// oversized trash directory never loads everything into memory at once.
func (s *Store) forEachTrashEntry(visit func(TrashEntry) bool) error {
	dir, err := s.openTrashDirNoFollow()
	if err != nil {
		return err
	}
	defer dir.Close()
	for {
		items, readErr := dir.ReadDir(512)
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			return readErr
		}
		for _, item := range items {
			if !strings.HasSuffix(item.Name(), ".json") {
				continue
			}
			id := strings.TrimSuffix(item.Name(), ".json")
			if !trashIDRule.MatchString(id) {
				continue
			}
			entry, err := readTrashJournalFromDir(dir, id)
			if err != nil {
				continue
			}
			if _, err := s.root.Lstat(path.Join(Trash, id)); err != nil {
				continue
			}
			if !visit(entry) {
				return nil
			}
		}
		if readErr == nil && len(items) > 0 {
			continue
		}
		return nil
	}
}

// TrashList returns at most maxTrashListEntries entries for one API response.
// The cap bounds response size only: the sweeper enumerates via
// forEachTrashEntry without it, so an oversized trash is always drainable
// instead of locking the list endpoint behind a trash_too_large error.
func (s *Store) TrashList() ([]TrashEntry, error) {
	out := make([]TrashEntry, 0)
	err := s.forEachTrashEntry(func(entry TrashEntry) bool {
		out = append(out, entry)
		return len(out) < maxTrashListEntries
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Store) TrashInfo(id string) (TrashEntry, error) {
	entry, err := s.readTrashJournal(id)
	if err != nil {
		return TrashEntry{}, err
	}
	if _, err := validate(entry.OriginalPath, false); err != nil {
		return TrashEntry{}, err
	}
	if _, err := s.root.Lstat(path.Join(Trash, id)); err != nil {
		return TrashEntry{}, err
	}
	return entry, nil
}

func (s *Store) Restore(id string) error {
	unlock, err := s.lockTrash()
	if err != nil {
		return err
	}
	defer unlock()
	return s.restoreLocked(id)
}

func (s *Store) restoreLocked(id string) error {
	entry, err := s.TrashInfo(id)
	if err != nil {
		return err
	}
	if err := s.verifyTrashIdentity(entry); err != nil {
		return err
	}
	name, err := s.safePath(entry.OriginalPath, false, true)
	if err != nil {
		return err
	}
	if _, err := s.root.Lstat(name); err == nil {
		return ErrExists
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	parent := path.Dir(name)
	info, err := s.root.Stat(parent)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return ErrType
	}
	from := path.Join(Trash, id)
	if err := s.renameEntry(from, name); err != nil {
		return err
	}
	if err := s.syncRename(from, name); err != nil {
		// The restore is visible but not durable. Put the item back under its
		// journal so the trash still accounts for it, and only then report
		// failure; if even that fails the journal remains the record. The trash
		// name must still be free, otherwise the undo would replace it.
		if _, statErr := s.root.Lstat(from); !errors.Is(statErr, fs.ErrNotExist) {
			return fmt.Errorf("%w: restore is not durable and the trash name is reoccupied", ErrStorageSync)
		}
		if undoErr := s.renameEntry(name, from); undoErr != nil {
			return fmt.Errorf("%w: restore is not durable and rollback failed: %v", ErrStorageSync, undoErr)
		}
		if undoErr := s.syncRename(name, from); undoErr != nil {
			return fmt.Errorf("%w: restore rollback is not durable: %v", ErrStorageSync, undoErr)
		}
		return fmt.Errorf("%w: restore is not durable", ErrStorageSync)
	}
	// The content is back at its original name and that move is durable, so
	// forgetting the journal cannot lose track of any remaining trash content.
	if err := s.removeTrashJournal(id); err != nil {
		return fmt.Errorf("restored but trash journal cleanup failed: %w", err)
	}
	return nil
}

// Trash never permanently deletes user content. Internal items are not
// accessible through public APIs and deletion requires an authenticated user.
//
// The journal is written and synced *before* the item moves, so an interruption
// can never leave trash content that no journal describes. After the move both
// the trash and original directories are synced; only then is success
// reported. A failure after publication is rolled back through the same
// primitives, and a rollback that cannot be completed is reported explicitly.
func (s *Store) MoveToTrash(raw string) error {
	unlock, err := s.lockTrash()
	if err != nil {
		return err
	}
	defer unlock()
	return s.moveToTrash(raw, nil)
}

// MoveToTrashIfUnchanged is the WebDAV overwrite/delete adapter. The expected
// descriptor-backed snapshot prevents a request from trashing a target that
// was replaced or modified after its DAV authorization check.
func (s *Store) MoveToTrashIfUnchanged(raw string, expected os.FileInfo) error {
	unlock, err := s.lockTrash()
	if err != nil {
		return err
	}
	defer unlock()
	return s.moveToTrash(raw, expected)
}

func (s *Store) moveToTrash(raw string, expected os.FileInfo) error {
	return s.moveToTrashWithID(raw, expected, randomName())
}

func (s *Store) moveToTrashWithID(raw string, expected os.FileInfo, id string) error {
	name, err := s.safePath(raw, false, false)
	if err != nil {
		return err
	}
	info, err := s.root.Lstat(name)
	if err != nil {
		return err
	}
	if expected != nil && !sameTrashTarget(info, expected) {
		return ErrTrashChanged
	}
	if !info.Mode().IsRegular() && !info.IsDir() {
		return ErrType
	}
	dst := path.Join(Trash, id)
	entry := TrashEntry{ID: id, OriginalPath: name, Name: path.Base(name), DeletedAt: time.Now().UTC(), ObjectIdentity: trashObjectIdentity(info)}
	// The trash name is random, but an accidental collision must never replace
	// another item: root.Rename would overwrite it and strand its journal.
	if _, err := s.root.Lstat(dst); err == nil {
		return ErrExists
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if err := s.writeTrashJournal(entry); err != nil {
		return err
	}
	if err := s.renameEntry(name, dst); err != nil {
		if cleanupErr := s.removeTrashJournal(id); cleanupErr != nil {
			return fmt.Errorf("trash move failed: %w; journal cleanup failed: %v", err, cleanupErr)
		}
		return err
	}
	if err := s.syncRename(name, dst); err != nil {
		// Content is in the trash but the move is not durable. Return it to its
		// original name before removing its journal; if the undo fails the
		// journal is kept, so recovery can still find the item. Never overwrite
		// whatever may have appeared at the original name in the meantime.
		if _, statErr := s.root.Lstat(name); !errors.Is(statErr, fs.ErrNotExist) {
			return fmt.Errorf("%w: trash move is not durable and the original name is occupied", ErrStorageSync)
		}
		if undoErr := s.renameEntry(dst, name); undoErr != nil {
			return fmt.Errorf("%w: trash move is not durable and rollback failed: %v", ErrStorageSync, undoErr)
		}
		if undoErr := s.syncRename(dst, name); undoErr != nil {
			return fmt.Errorf("%w: trash rollback is not durable", ErrStorageSync)
		}
		if cleanupErr := s.removeTrashJournal(id); cleanupErr != nil {
			return fmt.Errorf("%w: trash rollback journal cleanup failed: %v", ErrStorageSync, cleanupErr)
		}
		return fmt.Errorf("%w: trash move is not durable", ErrStorageSync)
	}
	// A local process can replace the source between its initial stat and the
	// rename. Keep the journal and content for inspection if that happened.
	if err := s.verifyTrashIdentity(entry); err != nil {
		return err
	}
	return nil
}

// Legacy journals have no identity and retain their existing behavior. New
// journals must refer to the object captured before the move; a replacement
// must not be silently restored or permanently removed as the original.
func (s *Store) verifyTrashIdentity(entry TrashEntry) error {
	if entry.ObjectIdentity == "" {
		return nil
	}
	info, err := s.root.Lstat(path.Join(Trash, entry.ID))
	if err != nil {
		return err
	}
	if trashObjectIdentity(info) != entry.ObjectIdentity {
		return ErrTrashChanged
	}
	return nil
}

func sameTrashTarget(actual, expected os.FileInfo) bool {
	if actual == nil || expected == nil || os.SameFile(actual, expected) == false ||
		actual.Mode().Type() != expected.Mode().Type() || actual.Size() != expected.Size() ||
		!actual.ModTime().Equal(expected.ModTime()) {
		return false
	}
	return actual.Mode().IsRegular() || actual.IsDir()
}
