package files

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"math"
	"os"
	"path"
	"regexp"
	"syscall"
	"time"
)

const (
	uploadsDir       = ".lightisle-parts"
	maxChunk         = int64(8 << 20)
	maxResumableSize = int64(32 << 30)
)

type UploadState struct {
	Version  int    `json:"version,omitempty"`
	ID       string `json:"id"`
	Path     string `json:"path"`
	Size     int64  `json:"size"`
	Offset   int64  `json:"offset"`
	Owner    int64  `json:"owner"`
	Created  int64  `json:"created"`
	Activity int64  `json:"activity"`
	// Published is set after an exclusive rename into the final destination
	// and its directory change are durable. Recovery also recognizes legacy
	// part/destination hardlinks while both names still exist.
	Published      bool                `json:"published,omitempty"`
	sourceIdentity *uploadFileIdentity `json:"-"`
}

// sourceIdentity is durably recorded immediately before the staged inode is
// moved into place. It lets recovery prove that a destination with no part is
// the file this upload published, rather than a same-sized external file.
type uploadFileIdentity struct {
	Device     uint64 `json:"device"`
	Inode      uint64 `json:"inode"`
	Size       int64  `json:"size"`
	ChangeSec  int64  `json:"changeSec"`
	ChangeNsec int64  `json:"changeNsec"`
	BirthSec   int64  `json:"birthSec"`
	BirthNsec  int64  `json:"birthNsec"`
	Generation uint32 `json:"generation"`
}

type uploadJournal struct {
	UploadState
	SourceIdentity *uploadFileIdentity `json:"sourceIdentity,omitempty"`
}

var ErrOffset = errors.New("offset_mismatch")
var ErrOwner = errors.New("upload_owner_mismatch")
var ErrPublished = errors.New("upload_already_published")
var ErrUploadBusy = errors.New("upload_busy")
var ErrInsufficientSpace = errors.New("insufficient_storage_space")
var ErrStorageSync = errors.New("storage_durability_failure")
var ErrPublishedSync = fmt.Errorf("%w: upload_outcome_uncertain", ErrStorageSync)

// ErrUploadCorrupt reports upload state that cannot safely be resumed. The
// owner can still release the staging journal with AbortUpload.
var ErrUploadCorrupt = errors.New("upload_state_corrupt")

func (s *Store) availableUploadBytes(part *os.File) (int64, error) {
	if s.uploadFreeBytes != nil {
		return s.uploadFreeBytes(part)
	}
	var stat syscall.Statfs_t
	if err := syscall.Fstatfs(int(part.Fd()), &stat); err != nil {
		return 0, fmt.Errorf("upload storage availability check: %w", err)
	}
	blocks, size := int64(stat.Bavail), int64(stat.Bsize)
	if blocks < 0 || size <= 0 {
		return 0, ErrInsufficientSpace
	}
	if blocks > math.MaxInt64/size {
		return math.MaxInt64, nil
	}
	return blocks * size, nil
}

func uploadOutcomeUncertain(reason string) error {
	return errors.Join(ErrPublishedSync, fmt.Errorf("%w: %s", ErrUploadCorrupt, reason))
}

var uploadIDPattern = regexp.MustCompile("^[a-f0-9]{32}$")

// Uploads are rooted inside the selected share. Opening the same part from
// another root cannot complete a transfer into a different volume.
func (s *Store) ensureUploads() error {
	_, _, err := s.openUploadsRoot()
	return err
}

func (s *Store) openUploadsRoot() (*os.Root, *os.File, error) {
	return s.openUploadsRootMode(true)
}

func (s *Store) openExistingUploadsRoot() (*os.Root, *os.File, error) {
	return s.openUploadsRootMode(false)
}

func (s *Store) openUploadsRootMode(create bool) (*os.Root, *os.File, error) {
	s.uploadsRootMu.Lock()
	defer s.uploadsRootMu.Unlock()
	if s.uploadsRoot != nil && s.uploadsDirFile != nil {
		current, err := s.openUploadsDirNoFollow()
		if err != nil {
			return nil, nil, err
		}
		currentInfo, statErr := current.Stat()
		pinnedInfo, pinnedErr := s.uploadsDirFile.Stat()
		closeErr := current.Close()
		if statErr != nil {
			return nil, nil, statErr
		}
		if pinnedErr != nil {
			return nil, nil, pinnedErr
		}
		if closeErr != nil {
			return nil, nil, closeErr
		}
		if !os.SameFile(currentInfo, pinnedInfo) {
			return nil, nil, ErrType
		}
		return s.uploadsRoot, s.uploadsDirFile, nil
	}
	if create {
		if err := s.root.Mkdir(uploadsDir, 0700); err != nil {
			if !errors.Is(err, os.ErrExist) {
				return nil, nil, err
			}
		} else if err := s.syncDirectory("."); err != nil {
			return nil, nil, err
		}
	}
	// Open the directory without following links, then open an os.Root for
	// convenient relative operations. Comparing the two handles closes the
	// race where the path is swapped between those opens.
	pinnedDir, err := s.openUploadsDirNoFollow()
	if err != nil {
		if !create && errors.Is(err, fs.ErrNotExist) {
			return nil, nil, nil
		}
		return nil, nil, err
	}
	pinnedInfo, err := pinnedDir.Stat()
	if err != nil {
		pinnedDir.Close()
		return nil, nil, err
	}
	uploadsRoot, err := s.root.OpenRoot(uploadsDir)
	if err != nil {
		pinnedDir.Close()
		return nil, nil, err
	}
	rootInfo, err := uploadsRoot.Stat(".")
	if err != nil {
		_ = uploadsRoot.Close()
		_ = pinnedDir.Close()
		return nil, nil, err
	}
	if !rootInfo.IsDir() || !os.SameFile(pinnedInfo, rootInfo) {
		_ = uploadsRoot.Close()
		_ = pinnedDir.Close()
		return nil, nil, ErrType
	}
	s.uploadsRoot = uploadsRoot
	s.uploadsDirFile = pinnedDir
	return uploadsRoot, pinnedDir, nil
}

func (s *Store) readUploadJournal(id string) (UploadState, error) {
	root, _, err := s.openExistingUploadsRoot()
	if err != nil {
		return UploadState{}, err
	}
	if root == nil {
		return UploadState{}, fs.ErrNotExist
	}
	return readUploadJournalFrom(root, id)
}

func readUploadJournalFrom(root *os.Root, id string) (UploadState, error) {
	if !uploadIDPattern.MatchString(id) {
		return UploadState{}, ErrPath
	}
	metadataPath := id + ".json"
	metadataInfo, err := root.Lstat(metadataPath)
	if err != nil {
		return UploadState{}, err
	}
	if !metadataInfo.Mode().IsRegular() || metadataInfo.Size() > maxUploadJournalBytes {
		return UploadState{}, ErrType
	}
	f, err := root.Open(metadataPath)
	if err != nil {
		return UploadState{}, err
	}
	data, readErr := io.ReadAll(io.LimitReader(f, maxUploadJournalBytes+1))
	closeErr := f.Close()
	if readErr != nil {
		return UploadState{}, readErr
	}
	if closeErr != nil {
		return UploadState{}, closeErr
	}
	if len(data) > maxUploadJournalBytes {
		return UploadState{}, ErrType
	}
	var journal uploadJournal
	if err := json.Unmarshal(data, &journal); err != nil || journal.ID != id {
		return UploadState{}, ErrPath
	}
	meta := journal.UploadState
	meta.sourceIdentity = journal.SourceIdentity
	if meta.Activity <= 0 {
		meta.Activity = meta.Created
	}
	return meta, nil
}

func (s *Store) uploadMeta(id string) (UploadState, error) {
	root, _, err := s.openExistingUploadsRoot()
	if err != nil {
		return UploadState{}, err
	}
	if root == nil {
		return UploadState{}, fs.ErrNotExist
	}
	meta, err := readUploadJournalFrom(root, id)
	if err != nil {
		return UploadState{}, err
	}
	partPath := id + ".part"
	partInfo, partErr := root.Lstat(partPath)
	if partErr != nil && !errors.Is(partErr, fs.ErrNotExist) {
		return UploadState{}, partErr
	}
	if partErr == nil && !partInfo.Mode().IsRegular() {
		return UploadState{}, ErrType
	}
	if meta.Published {
		if meta.Offset != meta.Size || meta.Size < 0 || meta.Offset < 0 || meta.Size > maxResumableSize {
			return UploadState{}, ErrSize
		}
		if _, err := s.safePath(meta.Path, false, true); err != nil {
			return UploadState{}, err
		}
		destInfo, destErr := s.root.Lstat(meta.Path)
		if destErr != nil && !errors.Is(destErr, fs.ErrNotExist) {
			return UploadState{}, destErr
		}
		if destErr == nil && !destInfo.Mode().IsRegular() {
			return UploadState{}, ErrType
		}
		if meta.sourceIdentity == nil && partErr != nil {
			// Legacy linked uploads can only be proven while both names exist.
			// A destination alone could have been replaced after the part vanished.
			return UploadState{}, uploadOutcomeUncertain("legacy published upload has no staged inode to verify its destination")
		}
		if meta.sourceIdentity != nil {
			if partErr == nil {
				partIdentity, ok := uploadIdentity(partInfo)
				partMatches := ok && sameUploadSource(meta.sourceIdentity, &partIdentity)
				destinationMatches := destErr == nil && sameUploadInode(meta.sourceIdentity, destInfo)
				if !partMatches && !destinationMatches {
					return UploadState{}, uploadOutcomeUncertain("published destination and staged part do not match the durable publishing identity")
				}
			} else if destErr != nil || !sameUploadInode(meta.sourceIdentity, destInfo) {
				return UploadState{}, uploadOutcomeUncertain("published destination cannot be proven to be the staged inode")
			}
		}
		// Report every published journal combination so its owner can reach
		// FinishUpload or AbortUpload: a missing destination is republished
		// from the part, a missing part is reconciled with the destination,
		// and a foreign destination is released without being touched.
		return meta, nil
	}
	if partErr == nil {
		// Older versions linked the final destination to the staged inode. A
		// missing Published marker must never make UploadInfo truncate that
		// inode after SMB or another process has extended the destination.
		if _, err := s.safePath(meta.Path, false, true); err != nil {
			return UploadState{}, err
		}
		destInfo, destErr := s.root.Lstat(meta.Path)
		if destErr != nil && !errors.Is(destErr, fs.ErrNotExist) {
			return UploadState{}, destErr
		}
		if destErr == nil && destInfo.Mode().IsRegular() && os.SameFile(partInfo, destInfo) {
			meta.Published = true
			return meta, nil
		}
		if err := validatePrivateUploadPart(partInfo); err != nil {
			return UploadState{}, err
		}
	}
	if partErr != nil {
		// A rename-based publication leaves no part. Recover it only when the
		// journal's durable device/inode identity proves the destination is the
		// staged inode; a foreign same-sized file is never enough evidence.
		if errors.Is(partErr, fs.ErrNotExist) && meta.Offset == meta.Size {
			if _, err := s.safePath(meta.Path, false, true); err != nil {
				return UploadState{}, err
			}
			destInfo, destErr := s.root.Lstat(meta.Path)
			if destErr == nil && destInfo.Mode().IsRegular() {
				if sameUploadInode(meta.sourceIdentity, destInfo) {
					meta.Published = true
					return meta, nil
				}
				return UploadState{}, uploadOutcomeUncertain("destination identity cannot be attributed to the missing staged part")
			}
			if destErr != nil && !errors.Is(destErr, fs.ErrNotExist) {
				return UploadState{}, destErr
			}
			return UploadState{}, uploadOutcomeUncertain("both the staged part and expected destination are missing")
		}
		// Without staged bytes or a durable publishing identity, the journal
		// cannot resume and the destination cannot be safely attributed.
		return UploadState{}, partErr
	}
	if meta.Version < 2 {
		// Migration from v1, where each completed chunk was synced and
		// the file length, not JSON, tracked the upload offset.
		meta.Offset = partInfo.Size()
		meta.Version = 2
		if _, err := s.persistUpload(meta); err != nil {
			return UploadState{}, err
		}
	}
	if meta.Offset < 0 || partInfo.Size() < meta.Offset || meta.Offset > meta.Size {
		return UploadState{}, ErrSize
	}
	if meta.sourceIdentity != nil {
		identity, ok := uploadIdentity(partInfo)
		if !ok || !sameUploadSource(meta.sourceIdentity, &identity) {
			return UploadState{}, ErrUploadCorrupt
		}
	}
	if partInfo.Size() > meta.Offset {
		// Crash after data write but before metadata commit. Ignore all
		// uncommitted trailing bytes instead of publishing corrupt data.
		part, _, err := s.openUploadPart(root, id, os.O_RDWR, partInfo, meta.sourceIdentity)
		if err != nil {
			return UploadState{}, err
		}
		if err := validateOpenedUploadPart(part, partInfo, meta.sourceIdentity); err != nil {
			_ = part.Close()
			return UploadState{}, err
		}
		err = part.Truncate(meta.Offset)
		if err == nil {
			err = s.syncFileContents(part)
		}
		closeErr := part.Close()
		if err != nil {
			return UploadState{}, err
		}
		if closeErr != nil {
			return UploadState{}, closeErr
		}
	}
	return meta, nil
}

// persistUpload atomically publishes the committed offset only after the
// corresponding part bytes have been flushed. The rename is followed by a
// directory sync so the new journal itself is durable before callers treat
// the offset as committed.
//
// committed reports that the rename already made the new journal visible.
// When it is true and err is a directory-sync failure, callers must not roll
// back appended part bytes: the journal may survive, and startup recovery
// intentionally trims only bytes beyond the journal offset.
func (s *Store) persistUpload(meta UploadState) (committed bool, err error) {
	root, _, err := s.openExistingUploadsRoot()
	if err != nil {
		return false, err
	}
	if root == nil {
		return false, fs.ErrNotExist
	}
	data, err := json.Marshal(uploadJournal{UploadState: meta, SourceIdentity: meta.sourceIdentity})
	if err != nil {
		return false, err
	}
	tmp := ".lightisle-uploadmeta-" + randomName()
	f, err := root.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return false, err
	}
	removeTemp := true
	defer func() {
		if !removeTemp {
			return
		}
		if removeErr := root.Remove(tmp); removeErr != nil && !errors.Is(removeErr, fs.ErrNotExist) {
			err = errors.Join(err, fmt.Errorf("upload journal temp cleanup: %w", removeErr))
		}
	}()
	_, err = f.Write(data)
	if err == nil {
		err = s.syncFileContents(f)
	}
	closeErr := f.Close()
	if err != nil {
		return false, err
	}
	if closeErr != nil {
		return false, closeErr
	}
	if err := root.Rename(tmp, meta.ID+".json"); err != nil {
		return false, err
	}
	removeTemp = false
	// From here on the new journal is visible; a failed directory sync makes
	// its survival across a crash uncertain, but the appended bytes still
	// belong to the newest journal offset.
	return true, syncUploadsRoot(s, root)
}

func (s *Store) syncUploadsDirectory() error {
	root, _, err := s.openExistingUploadsRoot()
	if err != nil {
		return err
	}
	if root == nil {
		return fs.ErrNotExist
	}
	return syncUploadsRoot(s, root)
}

func syncUploadsRoot(s *Store, root *os.Root) error {
	dir, err := root.Open(".")
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

func (s *Store) BeginUpload(destination string, size, owner int64) (UploadState, error) {
	s.uploadMu.Lock()
	defer s.uploadMu.Unlock()

	if size < 0 || size > maxResumableSize {
		return UploadState{}, ErrSize
	}
	name, err := s.safePath(destination, false, true)
	if err != nil {
		return UploadState{}, err
	}
	parent := path.Dir(name)
	fi, err := s.root.Stat(parent)
	if err != nil {
		return UploadState{}, err
	}
	if !fi.IsDir() {
		return UploadState{}, ErrType
	}
	if _, err := s.root.Lstat(name); err == nil {
		return UploadState{}, ErrExists
	} else if !errors.Is(err, fs.ErrNotExist) {
		return UploadState{}, err
	}
	if err := s.ensureUploads(); err != nil {
		return UploadState{}, err
	}
	root, _, err := s.openUploadsRoot()
	if err != nil {
		return UploadState{}, err
	}
	id := randomName()
	now := time.Now().Unix()
	meta := UploadState{Version: 2, ID: id, Path: name, Size: size, Owner: owner, Created: now, Activity: now}
	partPath := id + ".part"
	file, err := root.OpenFile(partPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return UploadState{}, err
	}
	if err := s.syncFileContents(file); err != nil {
		file.Close()
		_ = root.Remove(partPath)
		return UploadState{}, err
	}
	if err := file.Close(); err != nil {
		_ = root.Remove(partPath)
		return UploadState{}, err
	}
	if _, err := s.persistUpload(meta); err != nil {
		removePartErr := root.Remove(partPath)
		if errors.Is(removePartErr, fs.ErrNotExist) {
			removePartErr = nil
		}
		removeJournalErr := root.Remove(id + ".json")
		if errors.Is(removeJournalErr, fs.ErrNotExist) {
			removeJournalErr = nil
		}
		cleanupErr := errors.Join(removePartErr, removeJournalErr, syncUploadsRoot(s, root))
		if cleanupErr != nil {
			return UploadState{}, fmt.Errorf("begin upload failed: %w; rollback failed: %v", err, cleanupErr)
		}
		return UploadState{}, err
	}
	return meta, nil
}

func (s *Store) UploadInfo(id string, owner int64) (UploadState, error) {
	s.uploadMu.Lock()
	defer s.uploadMu.Unlock()
	return s.uploadInfo(id, owner)
}

func (s *Store) uploadInfo(id string, owner int64) (UploadState, error) {
	meta, err := s.uploadMeta(id)
	if err != nil {
		return UploadState{}, err
	}
	if meta.Owner != owner {
		return UploadState{}, ErrOwner
	}
	return meta, nil
}

// Append accepts one exact chunk at a sequential offset. The HTTP layer
// enforces maxChunk and serializes concurrent writes via Manager upload mutex.
func (s *Store) AppendUpload(id string, owner, offset int64, source io.Reader) (UploadState, error) {
	s.uploadMu.Lock()
	defer s.uploadMu.Unlock()
	meta, err := s.uploadInfo(id, owner)
	if err != nil {
		return UploadState{}, err
	}
	if meta.Published {
		return meta, ErrOffset
	}
	if offset != meta.Offset {
		return meta, ErrOffset
	}
	remaining := meta.Size - offset
	if remaining < 0 {
		return meta, ErrOffset
	}
	data, err := io.ReadAll(io.LimitReader(source, maxChunk+1))
	if err != nil {
		return meta, err
	}
	count := int64(len(data))
	if count > maxChunk || count > remaining {
		return meta, ErrSize
	}
	root, _, err := s.openExistingUploadsRoot()
	if err != nil {
		return meta, err
	}
	if root == nil {
		return meta, fs.ErrNotExist
	}
	f, openedInfo, err := s.openUploadPart(root, id, os.O_WRONLY, nil, nil)
	if err != nil {
		return meta, err
	}
	initialIdentity, ok := uploadIdentity(openedInfo)
	if !ok {
		_ = f.Close()
		return meta, ErrUploadCorrupt
	}
	if count > 0 {
		freeBytes, spaceErr := s.availableUploadBytes(f)
		if spaceErr != nil {
			_ = f.Close()
			return meta, spaceErr
		}
		// Keep a modest reserve for SQLite journals and macOS filesystem
		// metadata. Check the opened staging inode's volume, never a pathname
		// that an external process could remount or replace.
		const reserveBytes int64 = 64 << 20
		if freeBytes < reserveBytes || count > freeBytes-reserveBytes {
			_ = f.Close()
			return meta, ErrInsufficientSpace
		}
	}
	rollback := func() {
		if err := validateOpenedUploadPart(f, openedInfo, &initialIdentity); err != nil {
			return
		}
		_ = f.Truncate(offset)
		_ = s.syncFileContents(f)
	}
	if _, err := f.WriteAt(data, offset); err != nil {
		rollback()
		f.Close()
		return meta, err
	}
	if err := s.syncFileContents(f); err != nil {
		rollback()
		f.Close()
		return meta, err
	}
	if err := validateOpenedUploadPart(f, openedInfo, &initialIdentity); err != nil {
		_ = f.Close()
		return UploadState{}, err
	}
	if err := f.Close(); err != nil {
		return meta, err
	}
	meta.Offset += count
	meta.Activity = time.Now().Unix()
	committed, err := s.persistUpload(meta)
	if err != nil {
		if committed {
			return meta, err
		}
		s.truncateUploadPart(id, offset, &initialIdentity)
		return UploadState{}, err
	}
	return meta, nil
}

// truncateUploadPart discards bytes beyond offset after a failed journal
// write. The truncation is itself synced so the next startup sees a part that
// matches the last committed journal.
func (s *Store) truncateUploadPart(id string, offset int64, expectedIdentity *uploadFileIdentity) {
	root, _, err := s.openExistingUploadsRoot()
	if err != nil {
		return
	}
	if root == nil {
		return
	}
	f, _, err := s.openUploadPart(root, id, os.O_WRONLY, nil, expectedIdentity)
	if err != nil {
		return
	}
	if err := validateOpenedUploadPart(f, nil, expectedIdentity); err != nil {
		_ = f.Close()
		return
	}
	if err := f.Truncate(offset); err == nil {
		_ = s.syncFileContents(f)
	}
	_ = f.Close()
}

func uploadIdentity(info os.FileInfo) (uploadFileIdentity, bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return uploadFileIdentity{}, false
	}
	return uploadFileIdentity{
		Device:     uint64(stat.Dev),
		Inode:      stat.Ino,
		Size:       info.Size(),
		ChangeSec:  stat.Ctimespec.Sec,
		ChangeNsec: stat.Ctimespec.Nsec,
		BirthSec:   stat.Birthtimespec.Sec,
		BirthNsec:  stat.Birthtimespec.Nsec,
		Generation: stat.Gen,
	}, true
}

func validatePrivateUploadPart(info os.FileInfo) error {
	if !info.Mode().IsRegular() {
		return ErrType
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Nlink != 1 {
		return ErrUploadCorrupt
	}
	return nil
}

func validateOpenedUploadPart(file *os.File, expectedInfo os.FileInfo, expectedIdentity *uploadFileIdentity) error {
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if err := validatePrivateUploadPart(info); err != nil {
		return err
	}
	if expectedInfo != nil && !os.SameFile(expectedInfo, info) {
		return ErrUploadCorrupt
	}
	if expectedIdentity != nil && !sameUploadInode(expectedIdentity, info) {
		return ErrUploadCorrupt
	}
	return nil
}

// openUploadPart validates the staging entry and then checks the opened file
// descriptor again. This catches a path replacement between Lstat and open
// before any write or truncate can touch another inode.
func (s *Store) openUploadPart(root *os.Root, id string, flags int, expectedInfo os.FileInfo, expectedIdentity *uploadFileIdentity) (*os.File, os.FileInfo, error) {
	partInfo, err := root.Lstat(id + ".part")
	if err != nil {
		return nil, nil, err
	}
	if err := validatePrivateUploadPart(partInfo); err != nil {
		return nil, nil, err
	}
	if expectedInfo != nil && !os.SameFile(expectedInfo, partInfo) {
		return nil, nil, ErrUploadCorrupt
	}
	if expectedIdentity != nil && !sameUploadInode(expectedIdentity, partInfo) {
		return nil, nil, ErrUploadCorrupt
	}
	if s.beforeUploadPartOpen != nil {
		s.beforeUploadPartOpen(id)
	}
	file, err := root.OpenFile(id+".part", flags, 0600)
	if err != nil {
		return nil, nil, err
	}
	openedInfo, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return nil, nil, err
	}
	if err := validatePrivateUploadPart(openedInfo); err != nil {
		_ = file.Close()
		return nil, nil, err
	}
	if !os.SameFile(partInfo, openedInfo) || (expectedInfo != nil && !os.SameFile(expectedInfo, openedInfo)) {
		_ = file.Close()
		return nil, nil, ErrUploadCorrupt
	}
	if expectedIdentity != nil && !sameUploadInode(expectedIdentity, openedInfo) {
		_ = file.Close()
		return nil, nil, ErrUploadCorrupt
	}
	return file, openedInfo, nil
}

func sameUploadSource(expected, actual *uploadFileIdentity) bool {
	return expected != nil && actual != nil && expected.Device == actual.Device && expected.Inode == actual.Inode &&
		expected.Size == actual.Size && expected.ChangeSec == actual.ChangeSec && expected.ChangeNsec == actual.ChangeNsec &&
		expected.BirthSec == actual.BirthSec && expected.BirthNsec == actual.BirthNsec && expected.Generation == actual.Generation
}

func sameUploadInode(expected *uploadFileIdentity, info os.FileInfo) bool {
	actual, ok := uploadIdentity(info)
	return ok && expected != nil && expected.Device == actual.Device && expected.Inode == actual.Inode &&
		expected.BirthSec == actual.BirthSec && expected.BirthNsec == actual.BirthNsec && expected.Generation == actual.Generation
}

// FinishUpload publishes the completed part exactly once. The staged inode's
// device and inode are durably recorded before an exclusive rename moves it to
// the destination. Recovery can therefore distinguish our moved file from an
// unrelated destination without ever changing a published inode.
func (s *Store) FinishUpload(id string, owner int64) error {
	s.uploadMu.Lock()
	defer s.uploadMu.Unlock()
	meta, err := s.uploadInfo(id, owner)
	if err != nil {
		return err
	}
	if meta.Offset != meta.Size {
		return ErrOffset
	}
	if _, err := s.safePath(meta.Path, false, true); err != nil {
		return err
	}
	if meta.Published {
		return s.finishPublishedUpload(meta)
	}
	root, _, err := s.openExistingUploadsRoot()
	if err != nil {
		return err
	}
	if root == nil {
		return fs.ErrNotExist
	}
	part, partInfo, err := s.openUploadPart(root, id, os.O_RDWR, nil, meta.sourceIdentity)
	if err != nil {
		return err
	}
	identity, ok := uploadIdentity(partInfo)
	if !ok {
		_ = part.Close()
		return ErrUploadCorrupt
	}
	if meta.sourceIdentity != nil && !sameUploadSource(meta.sourceIdentity, &identity) {
		_ = part.Close()
		return ErrUploadCorrupt
	}
	if partInfo.Size() != meta.Size {
		_ = part.Close()
		return ErrSize
	}
	if err := validateOpenedUploadPart(part, partInfo, &identity); err != nil {
		_ = part.Close()
		return err
	}
	syncErr := s.syncFileContents(part)
	closeErr := part.Close()
	if syncErr != nil {
		return syncErr
	}
	if closeErr != nil {
		return closeErr
	}
	if meta.sourceIdentity == nil {
		meta.sourceIdentity = &identity
		if _, err := s.persistUpload(meta); err != nil {
			return fmt.Errorf("upload_publish_identity_sync_failed: %w", err)
		}
	}
	if err := s.renameUploadPartNoReplace(id, meta.Path); err != nil {
		if errors.Is(err, ErrExists) {
			return fmt.Errorf("%w: destination is owned by another file; abort the upload to release staging", ErrExists)
		}
		return err
	}
	if err := s.syncDirectory(path.Dir(meta.Path)); err != nil {
		return fmt.Errorf("%w: %v", ErrPublishedSync, err)
	}
	if err := syncUploadsRoot(s, root); err != nil {
		return fmt.Errorf("%w: %v", ErrPublishedSync, err)
	}
	meta.Published = true
	if _, err := s.persistUpload(meta); err != nil {
		return fmt.Errorf("%w: published marker write: %w", ErrPublishedSync, err)
	}
	return s.finishPublishedUpload(meta)
}

// finishPublishedUpload removes the staging journal only after the destination
// is known to be the published inode. It is safe to call repeatedly.
func (s *Store) finishPublishedUpload(meta UploadState) error {
	root, _, err := s.openExistingUploadsRoot()
	if err != nil {
		return err
	}
	if root == nil {
		return fs.ErrNotExist
	}
	partPath := meta.ID + ".part"
	metaPath := meta.ID + ".json"
	destInfo, err := s.root.Lstat(meta.Path)
	switch {
	case err == nil:
		if !destInfo.Mode().IsRegular() {
			return ErrType
		}
		partInfo, partErr := root.Lstat(partPath)
		if partErr == nil {
			if !partInfo.Mode().IsRegular() {
				return ErrType
			}
			if !os.SameFile(partInfo, destInfo) {
				return fmt.Errorf("%w: published destination belongs to another file; abort to release staging", ErrExists)
			}
		} else if errors.Is(partErr, fs.ErrNotExist) && meta.sourceIdentity != nil && !sameUploadInode(meta.sourceIdentity, destInfo) {
			return uploadOutcomeUncertain("destination identity does not match the published upload")
		} else if errors.Is(partErr, fs.ErrNotExist) && meta.sourceIdentity == nil {
			return uploadOutcomeUncertain("legacy published destination has no staged inode to verify it")
		} else if !errors.Is(partErr, fs.ErrNotExist) {
			return partErr
		}
	case errors.Is(err, fs.ErrNotExist):
		partInfo, partErr := root.Lstat(partPath)
		if errors.Is(partErr, fs.ErrNotExist) {
			return uploadOutcomeUncertain("published upload has neither destination nor staged part")
		}
		if partErr != nil {
			return partErr
		}
		if !partInfo.Mode().IsRegular() {
			return ErrType
		}
		if err := validatePrivateUploadPart(partInfo); err != nil {
			return err
		}
		identity, ok := uploadIdentity(partInfo)
		if !ok {
			return ErrUploadCorrupt
		}
		if meta.sourceIdentity != nil && !sameUploadSource(meta.sourceIdentity, &identity) {
			return ErrUploadCorrupt
		}
		if meta.sourceIdentity == nil {
			meta.sourceIdentity = &identity
			if _, persistErr := s.persistUpload(meta); persistErr != nil {
				return fmt.Errorf("%w: %v", ErrPublishedSync, persistErr)
			}
		}
		if err := s.renameUploadPartNoReplace(meta.ID, meta.Path); err != nil {
			return err
		}
		if syncErr := s.syncDirectory(path.Dir(meta.Path)); syncErr != nil {
			return fmt.Errorf("%w: %v", ErrPublishedSync, syncErr)
		}
		if syncErr := syncUploadsRoot(s, root); syncErr != nil {
			return fmt.Errorf("%w: %v", ErrPublishedSync, syncErr)
		}
		if _, persistErr := s.persistUpload(meta); persistErr != nil {
			return fmt.Errorf("%w: %v", ErrPublishedSync, persistErr)
		}
	default:
		return err
	}
	if removeErr := root.Remove(partPath); removeErr != nil && !errors.Is(removeErr, fs.ErrNotExist) {
		return removeErr
	}
	if syncErr := syncUploadsRoot(s, root); syncErr != nil {
		return syncErr
	}
	if removeErr := root.Remove(metaPath); removeErr != nil && !errors.Is(removeErr, fs.ErrNotExist) {
		return removeErr
	}
	return syncUploadsRoot(s, root)
}

// AbortUpload discards the staging part and journal for its owner. A published
// destination has been moved out of staging, so aborting never touches it;
// this is also the owner-accessible cleanup for a published journal that
// FinishUpload cannot reconcile.
func (s *Store) AbortUpload(id string, owner int64) error {
	s.uploadMu.Lock()
	defer s.uploadMu.Unlock()
	return s.abortUpload(id, owner)
}

func (s *Store) abortUpload(id string, owner int64) error {
	root, _, err := s.openExistingUploadsRoot()
	if err != nil {
		return err
	}
	if root == nil {
		return fs.ErrNotExist
	}
	meta, err := readUploadJournalFrom(root, id)
	if err != nil {
		return err
	}
	if meta.Owner != owner {
		return ErrOwner
	}
	partPath := id + ".part"
	if info, statErr := root.Lstat(partPath); statErr == nil {
		if !info.Mode().IsRegular() {
			return ErrType
		}
	} else if !errors.Is(statErr, fs.ErrNotExist) {
		return statErr
	}
	if err := root.Remove(partPath); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if err := syncUploadsRoot(s, root); err != nil {
		return err
	}
	if err := root.Remove(id + ".json"); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return syncUploadsRoot(s, root)
}
