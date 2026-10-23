package files

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"regexp"
	"strings"
	"sync"
	"time"
)

var (
	ErrPath   = errors.New("path_not_allowed")
	ErrExists = errors.New("file_already_exists")
	ErrType   = errors.New("unsupported_file_type")
	ErrSize   = errors.New("upload_too_large")
)

const (
	Trash     = ".lightisle-trash"
	maxUpload = 1024 * 1024 * 1024 // M2 v0: max 1 GiB per request; resumable transfer is next
)

type Entry struct {
	Name     string    `json:"name"`
	Path     string    `json:"path"`
	Type     string    `json:"type"`
	Size     int64     `json:"size"`
	Modified time.Time `json:"modified"`
}

// safePath rejects symbolic links at *every* component rather than relying
// on os.Root's share-wide confinement. In particular a granted directory
// cannot alias a private sibling through a relative symlink.
// The check is defense-in-depth: processes able to mutate the share
// concurrently still require capability-scoped operations to prevent races.
func (s *Store) safePath(raw string, allowRoot, missingLeaf bool) (string, error) {
	name, err := validate(raw, allowRoot)
	if err != nil {
		return "", err
	}
	if name == "." {
		return name, nil
	}
	parts := strings.Split(name, "/")
	for i := range parts {
		partial := strings.Join(parts[:i+1], "/")
		info, err := s.root.Lstat(partial)
		if missingLeaf && i == len(parts)-1 && errors.Is(err, fs.ErrNotExist) {
			return name, nil
		}
		if err != nil {
			return "", err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return "", ErrPath
		}
		if i < len(parts)-1 && !info.IsDir() {
			return "", ErrType
		}
	}
	return name, nil
}

var trashIDRule = regexp.MustCompile(`^[0-9a-f]{32}$`)

type TrashEntry struct {
	ID           string    `json:"id"`
	OriginalPath string    `json:"originalPath"`
	Name         string    `json:"name"`
	DeletedAt    time.Time `json:"deletedAt"`
}

// readTrashJournal parses one trash journal. Journal files are the only record
// of an item's original location, so a malformed or mismatched journal is a
// path error rather than a partially trusted entry.
func (s *Store) readTrashJournal(id string) (TrashEntry, error) {
	if !trashIDRule.MatchString(id) {
		return TrashEntry{}, ErrPath
	}
	data, err := s.root.ReadFile(path.Join(Trash, id+".json"))
	if err != nil {
		return TrashEntry{}, err
	}
	var entry TrashEntry
	if json.Unmarshal(data, &entry) != nil || entry.ID != id {
		return TrashEntry{}, ErrPath
	}
	return entry, nil
}

// writeTrashJournal publishes an entry journal durably: its bytes are flushed,
// then the temp name is renamed, then the trash directory entry set is synced.
// Callers must write the journal *before* moving the user's item into the
// trash so an interruption can never leave an unrecorded trashed item.
func (s *Store) writeTrashJournal(entry TrashEntry) error {
	data, err := json.Marshal(entry)
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

func (s *Store) TrashList() ([]TrashEntry, error) {
	dir, err := s.root.Open(Trash)
	if err != nil {
		return nil, err
	}
	defer dir.Close()
	items, err := dir.ReadDir(3001)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	if len(items) > 3000 {
		return nil, fmt.Errorf("trash_too_large")
	}
	out := make([]TrashEntry, 0)
	for _, item := range items {
		if !strings.HasSuffix(item.Name(), ".json") {
			continue
		}
		id := strings.TrimSuffix(item.Name(), ".json")
		if !trashIDRule.MatchString(id) {
			continue
		}
		data, err := s.root.ReadFile(path.Join(Trash, item.Name()))
		if err != nil {
			continue
		}
		var entry TrashEntry
		if json.Unmarshal(data, &entry) != nil || entry.ID != id {
			continue
		}
		if _, err := s.root.Lstat(path.Join(Trash, id)); err != nil {
			continue
		}
		out = append(out, entry)
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
	entry, err := s.TrashInfo(id)
	if err != nil {
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

type Store struct {
	root *os.Root
	// uploadsRoot is opened once without following symlinks and remains bound
	// to the original staging directory inode for the lifetime of the Store.
	// uploadsDirFile supplies its directory descriptor for no-replace rename.
	uploadsRootMu  sync.Mutex
	uploadsRoot    *os.Root
	uploadsDirFile *os.File
	// uploadMu keeps journal/part transitions atomic with respect to admin
	// listing and cleanup, including when Store is used without Manager.
	uploadMu sync.Mutex
	// Injection points for durability and race tests. Nil fields use the
	// production implementations below.
	syncFile  func(*os.File) error
	syncDir   func(*os.File) error
	link      func(string, string) error
	rename    func(string, string) error
	remove    func(string) error
	statEntry func(*os.File, string) (os.FileInfo, error)
	// beforeUploadRemoval is used by race tests to replace the public staging
	// path after its directory handle has been pinned.
	beforeUploadRemoval func()
	// beforeUploadPartOpen exercises the Lstat/open replacement boundary.
	beforeUploadPartOpen func(string)
}

func (s *Store) syncFileContents(f *os.File) error {
	var err error
	if s.syncFile != nil {
		err = s.syncFile(f)
	} else {
		err = syncStorage(f)
	}
	if err != nil {
		return fmt.Errorf("%w: %w", ErrStorageSync, err)
	}
	return nil
}

func (s *Store) syncDirContents(f *os.File) error {
	var err error
	if s.syncDir != nil {
		err = s.syncDir(f)
	} else {
		err = syncDirectoryStorage(f)
	}
	if err != nil {
		return fmt.Errorf("%w: %w", ErrStorageSync, err)
	}
	return nil
}

// syncDirectory flushes one directory entry set through a held descriptor.
func (s *Store) syncDirectory(relative string) error {
	dir, err := s.openDirNoFollow(relative)
	if err != nil {
		return err
	}
	err = s.syncDirContents(dir)
	closeErr := dir.Close()
	if err != nil {
		return err
	}
	return closeErr
}

// syncTrashDirectory flushes the trash directory entry set. The trash name is
// rejected by validate, so it is opened through the root handle directly
// rather than through openDirNoFollow.
func (s *Store) syncTrashDirectory() error {
	dir, err := s.root.Open(Trash)
	if err != nil {
		return err
	}
	info, err := dir.Stat()
	if err != nil {
		dir.Close()
		return err
	}
	if !info.IsDir() {
		dir.Close()
		return ErrType
	}
	err = s.syncDirContents(dir)
	closeErr := dir.Close()
	if err != nil {
		return err
	}
	return closeErr
}

// syncEntryDirectory flushes the directory that holds a mutated entry.
func (s *Store) syncEntryDirectory(relative string) error {
	if relative == Trash {
		return s.syncTrashDirectory()
	}
	return s.syncDirectory(relative)
}

// syncRename makes a completed rename durable in both affected directories.
// The destination insertion is synced first: an interruption between the two
// barriers may leave a duplicate entry, which recovery can reconcile, while
// losing the destination after the source removal would lose the item.
func (s *Store) syncRename(from, to string) error {
	fromDir, toDir := path.Dir(from), path.Dir(to)
	if err := s.syncEntryDirectory(toDir); err != nil {
		return err
	}
	if fromDir == toDir {
		return nil
	}
	return s.syncEntryDirectory(fromDir)
}

// renameEntry moves one entry without replacing an existing destination.
// Paths inside the trash directory cannot be traversed by openDirNoFollow
// because the trash name is not a public path, so those renames go through the
// root handle. MoveToTrash and Restore use random or verified-free names, and
// the root handle keeps them confined to the share.
func (s *Store) renameEntry(from, to string) error {
	if path.Dir(from) == Trash || path.Dir(to) == Trash {
		return s.renameFile(from, to)
	}
	return s.renameExclusive(from, to)
}

// renameDurable publishes an exclusive rename and only succeeds once both
// directory entry sets have been synced.
func (s *Store) renameDurable(from, to string) error {
	if err := s.renameEntry(from, to); err != nil {
		return err
	}
	if err := s.syncRename(from, to); err != nil {
		return fmt.Errorf("%w: published rename is not durable: %v", ErrStorageSync, err)
	}
	return nil
}

func (s *Store) linkFile(oldname, newname string) error {
	if s.link != nil {
		return s.link(oldname, newname)
	}
	return s.root.Link(oldname, newname)
}

func (s *Store) renameFile(oldname, newname string) error {
	if s.rename != nil {
		return s.rename(oldname, newname)
	}
	return s.root.Rename(oldname, newname)
}

func (s *Store) removeFile(name string) error {
	if s.remove != nil {
		return s.remove(name)
	}
	return s.root.Remove(name)
}

func (s *Store) entryInfo(dir *os.File, name string) (os.FileInfo, error) {
	if s.statEntry != nil {
		return s.statEntry(dir, name)
	}
	return statEntryNoFollow(dir, name)
}

func Open(folder string) (*Store, error) {
	if err := os.MkdirAll(folder, 0700); err != nil {
		return nil, err
	}
	// Do not chmod existing data folders selected by the Mac owner.
	r, err := os.OpenRoot(folder)
	if err != nil {
		return nil, err
	}
	s := &Store{root: r}
	if err := s.ensureTrashDirectory(); err != nil {
		r.Close()
		return nil, err
	}
	return s, nil
}

// ensureTrashDirectory creates the trash directory and makes its parent entry
// durable. The trash directory is the destination of every recoverable delete,
// so it must survive a crash before it can be used.
func (s *Store) ensureTrashDirectory() error {
	if err := s.root.Mkdir(Trash, 0700); err != nil {
		if !errors.Is(err, fs.ErrExist) {
			return err
		}
	} else if err := s.syncDirectory("."); err != nil {
		return err
	}
	info, err := s.root.Lstat(Trash)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return ErrType
	}
	return nil
}
func (s *Store) Close() error {
	s.uploadsRootMu.Lock()
	defer s.uploadsRootMu.Unlock()
	var err error
	if s.uploadsRoot != nil {
		err = errors.Join(err, s.uploadsRoot.Close())
		s.uploadsRoot = nil
	}
	if s.uploadsDirFile != nil {
		err = errors.Join(err, s.uploadsDirFile.Close())
		s.uploadsDirFile = nil
	}
	return errors.Join(err, s.root.Close())
}
func validate(raw string, allowRoot bool) (string, error) {
	if raw == "" || raw == "." {
		if allowRoot {
			return ".", nil
		}
		return "", ErrPath
	}
	if strings.ContainsRune(raw, 92) || strings.HasPrefix(raw, "/") || strings.ContainsRune(raw, 0) {
		return "", ErrPath
	}
	for _, part := range strings.Split(raw, "/") {
		if part == "" || part == "." || part == ".." || strings.HasPrefix(part, ".lightisle-") || part == Trash {
			return "", ErrPath
		}
	}
	clean := path.Clean(raw)
	if clean == "." || clean != raw {
		return "", ErrPath
	}
	return clean, nil
}
func typeOf(fi os.FileInfo) string {
	if fi.IsDir() {
		return "folder"
	}
	if fi.Mode().IsRegular() {
		return "file"
	}
	return "unsupported"
}
func (s *Store) List(raw string) ([]Entry, error) {
	target, err := s.safePath(raw, true, false)
	if err != nil {
		return nil, err
	}
	dir, err := s.openDirNoFollow(target)
	if err != nil {
		return nil, err
	}
	defer dir.Close()
	stat, err := dir.Stat()
	if err != nil {
		return nil, err
	}
	if !stat.IsDir() {
		return nil, ErrType
	}
	entries, err := dir.ReadDir(1501)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	if len(entries) > 1500 {
		return nil, fmt.Errorf("too_many_entries: use smaller folders until pagination is implemented")
	}
	out := make([]Entry, 0, len(entries))
	for _, item := range entries {
		if strings.HasPrefix(item.Name(), ".lightisle-") {
			continue
		}
		fi, err := statEntryNoFollow(dir, item.Name())
		if err != nil {
			continue
		}
		t := typeOf(fi)
		if t == "unsupported" {
			continue
		}
		name := item.Name()
		p := name
		if target != "." {
			p = path.Join(target, name)
		}
		out = append(out, Entry{Name: name, Path: p, Type: t, Size: fi.Size(), Modified: fi.ModTime()})
	}
	return out, nil
}
func (s *Store) Read(raw string) (*os.File, os.FileInfo, error) {
	name, err := s.safePath(raw, false, false)
	if err != nil {
		return nil, nil, err
	}
	f, err := s.openFileNoFollow(name)
	if err != nil {
		return nil, nil, err
	}
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, err
	}
	if !fi.Mode().IsRegular() {
		f.Close()
		return nil, nil, ErrType
	}
	return f, fi, nil
}
func (s *Store) Mkdir(raw string) error {
	name, err := s.safePath(raw, false, true)
	if err != nil {
		return err
	}
	parent := path.Dir(name)
	fi, err := s.root.Stat(parent)
	if err != nil {
		return err
	}
	if !fi.IsDir() {
		return ErrType
	}
	if err := s.root.Mkdir(name, 0700); err != nil {
		return err
	}
	// A new folder is only acknowledged once its parent entry set is durable.
	return s.syncDirectory(parent)
}
func randomName() string {
	var buf [16]byte
	_, _ = rand.Read(buf[:])
	return hex.EncodeToString(buf[:])
}

// Upload is streamed into a random temporary file inside the target directory.
// A hard link commits only if the destination does not exist, avoiding overwrite
// of existing user files. Temporary file is removed on all failed writes.
//
// Durability ordering mirrors FinishUpload: the staged bytes are synced before
// publication, the exclusive link is only reported successful after the
// containing directory has been synced, and the staging name is removed last.
func (s *Store) Upload(raw string, source io.Reader) (int64, error) {
	name, err := s.safePath(raw, false, true)
	if err != nil {
		return 0, err
	}
	parent := path.Dir(name)
	fi, err := s.root.Stat(parent)
	if err != nil {
		return 0, err
	}
	if !fi.IsDir() {
		return 0, ErrType
	}
	tmp := path.Join(parent, ".lightisle-upload-"+randomName())
	f, err := s.root.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return 0, err
	}
	keepStaging := false
	defer func() {
		if !keepStaging {
			_ = s.root.Remove(tmp)
		}
	}()
	n, copyErr := io.Copy(f, io.LimitReader(source, maxUpload+1))
	if copyErr != nil {
		f.Close()
		return n, copyErr
	}
	if n > maxUpload {
		f.Close()
		return n, ErrSize
	}
	if err := s.syncFileContents(f); err != nil {
		f.Close()
		return n, err
	}
	if err := f.Close(); err != nil {
		return n, err
	}
	if err := s.syncDirectory(parent); err != nil {
		return n, err
	}
	if err := s.linkFile(tmp, name); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return 0, ErrExists
		}
		return 0, err
	}
	if err := s.syncDirectory(parent); err != nil {
		// Keep the durable staging name so a retry can verify and reconcile the
		// destination instead of losing the only known durable link.
		keepStaging = true
		return n, fmt.Errorf("%w: %v", ErrPublishedSync, err)
	}
	if err := s.removeFile(tmp); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return n, fmt.Errorf("%w: staging cleanup: %v", ErrPublishedSync, err)
	}
	if err := s.syncDirectory(parent); err != nil {
		return n, fmt.Errorf("%w: staging cleanup durability: %v", ErrPublishedSync, err)
	}
	return n, nil
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
	name, err := s.safePath(raw, false, false)
	if err != nil {
		return err
	}
	info, err := s.root.Lstat(name)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() && !info.IsDir() {
		return ErrType
	}
	id := randomName()
	dst := path.Join(Trash, id)
	entry := TrashEntry{ID: id, OriginalPath: name, Name: path.Base(name), DeletedAt: time.Now().UTC()}
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
	return nil
}
