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
	"time"
)

const (
	uploadsDir       = ".lightisle-parts"
	maxChunk         = int64(8 << 20)
	maxResumableSize = int64(32 << 30)
)

type UploadState struct {
	Version int    `json:"version,omitempty"`
	ID      string `json:"id"`
	Path    string `json:"path"`
	Size    int64  `json:"size"`
	Offset  int64  `json:"offset"`
	Owner   int64  `json:"owner"`
	Created int64  `json:"created"`
	// Published is set after the committed part has been linked to the final
	// destination and that link was made durable. It lets a retried completion
	// finish cleanup when the part has already been removed.
	Published bool `json:"published,omitempty"`
}

var ErrOffset = errors.New("offset_mismatch")
var ErrOwner = errors.New("upload_owner_mismatch")
var ErrPublished = errors.New("upload_already_published")
var ErrStorageSync = errors.New("storage_durability_failure")
var ErrPublishedSync = fmt.Errorf("%w: upload_outcome_uncertain", ErrStorageSync)

// ErrUploadCorrupt reports a published journal whose destination and staging
// part are both gone. The bytes cannot be recovered, but the owner can still
// release the journal with AbortUpload.
var ErrUploadCorrupt = errors.New("upload_state_corrupt")

var uploadIDPattern = regexp.MustCompile("^[a-f0-9]{32}$")

// Uploads are rooted inside the selected share. Opening the same part from
// another root cannot complete a transfer into a different volume.
func (s *Store) ensureUploads() error {
	e := s.root.Mkdir(uploadsDir, 0700)
	if errors.Is(e, os.ErrExist) {
		info, err := s.root.Lstat(uploadsDir)
		if err != nil {
			return err
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return ErrType
		}
		return nil
	}
	if e != nil {
		return e
	}
	// Do not report a durable upload session until the journals directory
	// itself survives a crash.
	return s.syncDirectory(".")
}

func (s *Store) readUploadJournal(id string) (UploadState, error) {
	if err := s.ensureUploads(); err != nil {
		return UploadState{}, err
	}
	if !uploadIDPattern.MatchString(id) {
		return UploadState{}, ErrPath
	}
	metadataPath := path.Join(uploadsDir, id+".json")
	metadataInfo, err := s.root.Lstat(metadataPath)
	if err != nil {
		return UploadState{}, err
	}
	if !metadataInfo.Mode().IsRegular() || metadataInfo.Size() > 4096 {
		return UploadState{}, ErrType
	}
	data, err := s.root.ReadFile(metadataPath)
	if err != nil {
		return UploadState{}, err
	}
	var meta UploadState
	if err := json.Unmarshal(data, &meta); err != nil || meta.ID != id {
		return UploadState{}, ErrPath
	}
	return meta, nil
}

func (s *Store) uploadMeta(id string) (UploadState, error) {
	meta, err := s.readUploadJournal(id)
	if err != nil {
		return UploadState{}, err
	}
	partPath := path.Join(uploadsDir, id+".part")
	partInfo, partErr := s.root.Lstat(partPath)
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
		// Report every published journal combination so its owner can reach
		// FinishUpload or AbortUpload: a missing destination is republished
		// from the part, a missing part is reconciled with the destination,
		// and a foreign destination is released without being touched.
		return meta, nil
	}
	if partErr != nil {
		// Without the staged bytes the journal cannot resume. Returning the
		// journaled offset would describe data that no longer exists.
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
	if partInfo.Size() > meta.Offset {
		// Crash after data write but before metadata commit. Ignore all
		// uncommitted trailing bytes instead of publishing corrupt data.
		part, err := s.root.OpenFile(partPath, os.O_RDWR, 0600)
		if err != nil {
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
	data, err := json.Marshal(meta)
	if err != nil {
		return false, err
	}
	tmp := path.Join(uploadsDir, ".lightisle-uploadmeta-"+randomName())
	f, err := s.root.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return false, err
	}
	removeTemp := true
	defer func() {
		if !removeTemp {
			return
		}
		if removeErr := s.removeFile(tmp); removeErr != nil && !errors.Is(removeErr, fs.ErrNotExist) {
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
	if err := s.renameFile(tmp, path.Join(uploadsDir, meta.ID+".json")); err != nil {
		return false, err
	}
	removeTemp = false
	// From here on the new journal is visible; a failed directory sync makes
	// its survival across a crash uncertain, but the appended bytes still
	// belong to the newest journal offset.
	return true, s.syncUploadsDirectory()
}

func (s *Store) syncUploadsDirectory() error {
	dir, err := s.root.Open(uploadsDir)
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
	id := randomName()
	meta := UploadState{Version: 2, ID: id, Path: name, Size: size, Owner: owner, Created: time.Now().Unix()}
	partPath := path.Join(uploadsDir, id+".part")
	file, err := s.root.OpenFile(partPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return UploadState{}, err
	}
	if err := s.syncFileContents(file); err != nil {
		file.Close()
		s.root.Remove(partPath)
		return UploadState{}, err
	}
	if err := file.Close(); err != nil {
		s.root.Remove(partPath)
		return UploadState{}, err
	}
	if _, err := s.persistUpload(meta); err != nil {
		removePartErr := s.removeFile(partPath)
		if errors.Is(removePartErr, fs.ErrNotExist) {
			removePartErr = nil
		}
		removeJournalErr := s.removeFile(path.Join(uploadsDir, id+".json"))
		if errors.Is(removeJournalErr, fs.ErrNotExist) {
			removeJournalErr = nil
		}
		cleanupErr := errors.Join(removePartErr, removeJournalErr, s.syncUploadsDirectory())
		if cleanupErr != nil {
			return UploadState{}, fmt.Errorf("begin upload failed: %w; rollback failed: %v", err, cleanupErr)
		}
		return UploadState{}, err
	}
	return meta, nil
}

func (s *Store) UploadInfo(id string, owner int64) (UploadState, error) {
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
	meta, err := s.UploadInfo(id, owner)
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
	partPath := path.Join(uploadsDir, id+".part")
	f, err := s.root.OpenFile(partPath, os.O_WRONLY, 0600)
	if err != nil {
		return meta, err
	}
	rollback := func() {
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
	if err := f.Close(); err != nil {
		return meta, err
	}
	meta.Offset += count
	committed, err := s.persistUpload(meta)
	if err != nil {
		if committed {
			return meta, err
		}
		s.truncateUploadPart(id, offset)
		return UploadState{}, err
	}
	return meta, nil
}

// truncateUploadPart discards bytes beyond offset after a failed journal
// write. The truncation is itself synced so the next startup sees a part that
// matches the last committed journal.
func (s *Store) truncateUploadPart(id string, offset int64) {
	f, err := s.root.OpenFile(path.Join(uploadsDir, id+".part"), os.O_WRONLY, 0600)
	if err != nil {
		return
	}
	if err := f.Truncate(offset); err == nil {
		_ = s.syncFileContents(f)
	}
	_ = f.Close()
}

func (s *Store) sameFile(a, b string) (bool, error) {
	ai, err := s.root.Lstat(a)
	if err != nil {
		return false, err
	}
	bi, err := s.root.Lstat(b)
	if err != nil {
		return false, err
	}
	return os.SameFile(ai, bi), nil
}

// linkPublished links the staged part to its destination without replacing an
// existing file. A destination that already names the part inode is a
// completed earlier attempt and is accepted; any other destination is foreign
// and must be released by its owner instead of being overwritten.
func (s *Store) linkPublished(partPath, destination string) error {
	if err := s.linkFile(partPath, destination); err != nil {
		if !errors.Is(err, fs.ErrExist) {
			return err
		}
		same, cmpErr := s.sameFile(partPath, destination)
		if cmpErr != nil {
			return cmpErr
		}
		if !same {
			return fmt.Errorf("%w: destination is owned by another file; abort the upload to release staging", ErrExists)
		}
	}
	return nil
}

// FinishUpload publishes the completed part exactly once. The ordering is:
// data sync, exclusive link, destination directory sync, journal "published"
// marker, then part/journal cleanup. A crash at any step leaves enough state
// for a retry to either resume publication or finish cleanup without
// overwriting a file created by someone else.
func (s *Store) FinishUpload(id string, owner int64) error {
	meta, err := s.UploadInfo(id, owner)
	if err != nil {
		return err
	}
	if meta.Offset != meta.Size {
		return ErrOffset
	}
	if _, err := s.safePath(meta.Path, false, true); err != nil {
		return err
	}
	partPath := path.Join(uploadsDir, id+".part")
	if meta.Published {
		return s.finishPublishedUpload(meta)
	}
	part, err := s.root.OpenFile(partPath, os.O_RDWR, 0600)
	if err != nil {
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
	// A previous attempt may have linked the destination but crashed before
	// the published marker; linkPublished accepts that durable link.
	if err := s.linkPublished(partPath, meta.Path); err != nil {
		return err
	}
	if err := s.syncDirectory(path.Dir(meta.Path)); err != nil {
		return fmt.Errorf("%w: %v", ErrPublishedSync, err)
	}
	meta.Published = true
	if _, err := s.persistUpload(meta); err != nil {
		return fmt.Errorf("upload_published_but_journal_sync_failed: %w", err)
	}
	return s.finishPublishedUpload(meta)
}

// finishPublishedUpload removes the staging part and journal only after the
// destination link is known to be durable. It is safe to call repeatedly.
func (s *Store) finishPublishedUpload(meta UploadState) error {
	partPath := path.Join(uploadsDir, meta.ID+".part")
	metaPath := path.Join(uploadsDir, meta.ID+".json")
	destInfo, err := s.root.Lstat(meta.Path)
	switch {
	case err == nil:
		if !destInfo.Mode().IsRegular() {
			return ErrType
		}
		partInfo, partErr := s.root.Lstat(partPath)
		if partErr == nil {
			if !partInfo.Mode().IsRegular() {
				return ErrType
			}
			if !os.SameFile(partInfo, destInfo) {
				return fmt.Errorf("%w: published destination belongs to another file; abort to release staging", ErrExists)
			}
		} else if !errors.Is(partErr, fs.ErrNotExist) {
			return partErr
		}
	case errors.Is(err, fs.ErrNotExist):
		partInfo, partErr := s.root.Lstat(partPath)
		if errors.Is(partErr, fs.ErrNotExist) {
			return fmt.Errorf("%w: published upload %s has neither destination nor staged part", ErrUploadCorrupt, meta.ID)
		}
		if partErr != nil {
			return partErr
		}
		if !partInfo.Mode().IsRegular() {
			return ErrType
		}
		if err := s.linkPublished(partPath, meta.Path); err != nil {
			return err
		}
		if syncErr := s.syncDirectory(path.Dir(meta.Path)); syncErr != nil {
			return fmt.Errorf("%w: %v", ErrPublishedSync, syncErr)
		}
		if _, persistErr := s.persistUpload(meta); persistErr != nil {
			return fmt.Errorf("%w: %v", ErrPublishedSync, persistErr)
		}
	default:
		return err
	}
	if removeErr := s.removeFile(partPath); removeErr != nil && !errors.Is(removeErr, fs.ErrNotExist) {
		return removeErr
	}
	if syncErr := s.syncUploadsDirectory(); syncErr != nil {
		return syncErr
	}
	if removeErr := s.removeFile(metaPath); removeErr != nil && !errors.Is(removeErr, fs.ErrNotExist) {
		return removeErr
	}
	return s.syncUploadsDirectory()
}

// AbortUpload discards the staging part and journal for its owner. A published
// journal's destination is an independent link, so aborting never touches it;
// this is also the owner-accessible cleanup for a published journal that
// FinishUpload cannot reconcile.
func (s *Store) AbortUpload(id string, owner int64) error {
	meta, err := s.readUploadJournal(id)
	if err != nil {
		return err
	}
	if meta.Owner != owner {
		return ErrOwner
	}
	partPath := path.Join(uploadsDir, id+".part")
	if info, statErr := s.root.Lstat(partPath); statErr == nil {
		if !info.Mode().IsRegular() {
			return ErrType
		}
	} else if !errors.Is(statErr, fs.ErrNotExist) {
		return statErr
	}
	if err := s.removeFile(partPath); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if err := s.syncUploadsDirectory(); err != nil {
		return err
	}
	if err := s.removeFile(path.Join(uploadsDir, id+".json")); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return s.syncUploadsDirectory()
}
