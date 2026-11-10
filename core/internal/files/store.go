package files

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

var (
	ErrPath                     = errors.New("path_not_allowed")
	ErrExists                   = errors.New("file_already_exists")
	ErrType                     = errors.New("unsupported_file_type")
	ErrSize                     = errors.New("upload_too_large")
	ErrTrashChanged             = errors.New("trash_item_changed")
	ErrTrashIdentityUnknown     = errors.New("trash_identity_unknown")
	ErrTrashAccountingUncertain = errors.New("trash_accounting_uncertain")
)

const (
	Trash     = ".lightisle-trash"
	maxUpload = 1024 * 1024 * 1024 // M2 v0: max 1 GiB per request; resumable transfer is next
	// maxTrashListEntries bounds one trash list API response. It is not a
	// store limit: the sweeper enumerates trash without it.
	maxTrashListEntries = 3000
	// Journals contain paths/timestamps, never file contents. Bound even a
	// corrupted or locally replaced journal before allocating its contents.
	maxTrashJournalBytes = 64 << 10
)

type Entry struct {
	Name     string    `json:"name"`
	Path     string    `json:"path"`
	Type     string    `json:"type"`
	Size     int64     `json:"size"`
	Modified time.Time `json:"modified"`
	// Identity is internal scan metadata, never part of the public files API.
	Identity   string `json:"-"`
	SingleLink bool   `json:"-"`
}

// OpenPinnedStore clones an already identity-verified os.Root. Unlike Open,
// it never re-resolves a mount path, so a disk replaced at the same pathname
// cannot redirect native migration or maintenance writes to a new volume.
// The caller keeps its original directory lease alive for the Store lifetime.
func OpenPinnedStore(verified *os.Root) (*Store, error) {
	if verified == nil {
		return nil, ErrPath
	}
	clone, err := verified.OpenRoot(".")
	if err != nil {
		return nil, err
	}
	s := &Store{root: clone}
	if err := s.ensureTrashDirectory(); err != nil {
		_ = clone.Close()
		return nil, err
	}
	return s, nil
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
	// uploadFreeBytes permits deterministic low-space tests. Production uses
	// Fstatfs on the already validated upload part descriptor.
	uploadFreeBytes func(*os.File) (int64, error)
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

// syncTrashDirectory flushes the private trash without following aliases.
func (s *Store) syncTrashDirectory() error {
	dir, err := s.openTrashDirNoFollow()
	if err != nil {
		return err
	}
	defer dir.Close()
	return s.syncDirContents(dir)
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
// Trash moves use private dirfd access, including both rollback directions.
func (s *Store) renameEntry(from, to string) error {
	if path.Dir(from) == Trash || path.Dir(to) == Trash {
		if s.rename != nil {
			return s.rename(from, to)
		}
		if path.Dir(from) == Trash {
			return s.renameTrashToNoReplace(path.Base(from), to)
		}
		return s.renameSourceToTrashNoReplace(from, path.Base(to))
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

// IsInternalName rejects case aliases of private metadata on macOS volumes.
func IsInternalName(component string) bool {
	const prefix = ".lightisle-"
	return len(component) >= len(prefix) && strings.EqualFold(component[:len(prefix)], prefix)
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
		if part == "" || part == "." || part == ".." || IsInternalName(part) {
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
		return nil, fmt.Errorf("too_many_entries: folder too large for an unpaginated listing; use the paginated page API")
	}
	out := make([]Entry, 0, len(entries))
	for _, item := range entries {
		if IsInternalName(item.Name()) {
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

// Stat resolves safe-path metadata for both files and directories without
// opening the object for reading. os.Root.Stat reports the link itself for a
// final symlink, so anything but a plain file or directory stays ErrType.
func (s *Store) Stat(raw string) (os.FileInfo, error) {
	name, err := s.safePath(raw, false, false)
	if err != nil {
		return nil, err
	}
	fi, err := s.root.Stat(name)
	if err != nil {
		return nil, err
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return nil, ErrType
	}
	if !fi.Mode().IsRegular() && !fi.IsDir() {
		return nil, ErrType
	}
	return fi, nil
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
	return s.uploadBounded(raw, source, maxUpload, nil)
}

// UploadWithIdentity captures the published inode through the same open file
// descriptor used for writing. An empty identity means it cannot be verified;
// callers must not infer one by reopening the destination path later.
func (s *Store) UploadWithIdentity(raw string, source io.Reader) (int64, string, error) {
	var identity string
	n, err := s.uploadBounded(raw, source, maxUpload, &identity)
	return n, identity, err
}

// maxLocalPublishBytes bounds publications of bytes that are already local
// and size-verified (download staging); the request-sized maxUpload cap must
// not reject a finished multi-gigabyte download at publish time. The value
// mirrors the download task ceiling in the downloads package.
const maxLocalPublishBytes = int64(1) << 40

// PublishLocal runs the same atomic no-replace publication as Upload with the
// local-publication ceiling instead of the HTTP request cap.
func (s *Store) PublishLocal(raw string, source io.Reader) (int64, error) {
	return s.uploadBounded(raw, source, maxLocalPublishBytes, nil)
}

func (s *Store) uploadBounded(raw string, source io.Reader, limit int64, capturedIdentity *string) (int64, error) {
	name, err := validate(raw, false)
	if err != nil {
		return 0, err
	}
	parent := path.Dir(name)
	dir, err := s.openDirNoFollow(parent)
	if err != nil {
		return 0, err
	}
	defer dir.Close()
	parentInfo, err := dir.Stat()
	if err != nil {
		return 0, err
	}
	fd := int(dir.Fd())
	tmp := ".lightisle-upload-" + randomName()
	stageFD, err := unix.Openat(fd, tmp, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0600)
	if err != nil {
		return 0, err
	}
	f := os.NewFile(uintptr(stageFD), path.Join(dir.Name(), tmp))
	defer f.Close()
	var stageInfo unix.Stat_t
	if err := unix.Fstat(stageFD, &stageInfo); err != nil {
		return 0, err
	}
	sameEntry := func(leaf string) bool {
		var info unix.Stat_t
		return unix.Fstat(stageFD, &stageInfo) == nil &&
			unix.Fstatat(fd, leaf, &info, unix.AT_SYMLINK_NOFOLLOW) == nil &&
			info.Dev == stageInfo.Dev && info.Ino == stageInfo.Ino
	}
	parentCurrent := func() bool {
		current, err := s.openDirNoFollow(parent)
		if err != nil {
			return false
		}
		defer current.Close()
		info, err := current.Stat()
		return err == nil && os.SameFile(parentInfo, info)
	}
	keepStaging := false
	defer func() {
		if !keepStaging && sameEntry(tmp) {
			_ = unix.Unlinkat(fd, tmp, 0)
		}
	}()
	writer := &uploadStreamWriter{store: s, file: f, limit: limit}
	n, copyErr := io.CopyBuffer(writer, io.LimitReader(source, limit+1), make([]byte, uploadBufferSize))
	if copyErr != nil {
		return n, copyErr
	}
	if err := s.syncFileContents(f); err != nil {
		return n, err
	}
	if err := s.syncDirContents(dir); err != nil {
		return n, err
	}
	if !parentCurrent() || !sameEntry(tmp) {
		return n, ErrPath
	}
	leaf := path.Base(name)
	usedRename := false
	if err := unix.Linkat(fd, tmp, fd, leaf, 0); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return 0, ErrExists
		}
		if !errors.Is(err, unix.ENOTSUP) && !errors.Is(err, unix.EOPNOTSUPP) {
			return 0, err
		}
		if err := renameAtNoReplace(fd, tmp, fd, leaf); err != nil {
			if errors.Is(err, fs.ErrExist) {
				return 0, ErrExists
			}
			return 0, err
		}
		usedRename = true
	}
	if !parentCurrent() || !sameEntry(leaf) {
		// Publication happened on the pinned directory. Preserve the staging
		// link and accounting until the interrupted result can be inspected.
		keepStaging = true
		return n, fmt.Errorf("%w: upload directory or entry changed", ErrPublishedSync)
	}
	if err := s.syncDirContents(dir); err != nil {
		keepStaging = true
		return n, fmt.Errorf("%w: %v", ErrPublishedSync, err)
	}
	if !usedRename {
		if !parentCurrent() || !sameEntry(tmp) {
			keepStaging = true
			return n, fmt.Errorf("%w: upload directory or staging entry changed", ErrPublishedSync)
		}
		if err := unix.Unlinkat(fd, tmp, 0); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return n, fmt.Errorf("%w: staging cleanup: %v", ErrPublishedSync, err)
		}
		if err := s.syncDirContents(dir); err != nil {
			return n, fmt.Errorf("%w: staging cleanup durability: %v", ErrPublishedSync, err)
		}
	}
	if capturedIdentity != nil {
		if !parentCurrent() || !sameEntry(leaf) {
			return n, fmt.Errorf("%w: published entry changed before identity capture", ErrPublishedSync)
		}
		info, err := f.Stat()
		if err == nil && info.Size() == n && MediaFileHasSingleLink(info) {
			*capturedIdentity = MediaFileIdentity(info)
		}
	}
	return n, nil
}
