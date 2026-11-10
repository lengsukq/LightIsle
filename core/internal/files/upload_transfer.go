package files

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"sync"
	"syscall"
	"time"
)

func (s *Store) BeginUpload(destination string, size, owner int64) (UploadState, error) {
	return s.BeginUploadWithID(destination, size, owner, "", "", "")
}

func (s *Store) BeginUploadWithID(destination string, size, owner int64, id, original, conflict string) (UploadState, error) {
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
	if id == "" {
		id = randomName()
	} else if !uploadIDPattern.MatchString(id) {
		return UploadState{}, ErrPath
	} else if _, err := root.Lstat(id + ".json"); !errors.Is(err, fs.ErrNotExist) {
		return UploadState{}, errors.Join(ErrUploadBeginUncertain, err)
	}
	now := time.Now().Unix()
	meta := UploadState{Version: 2, ID: id, Path: name, Size: size, Owner: owner, Created: now, Activity: now, RequestedPath: original, ConflictPolicy: conflict}
	partPath := id + ".part"
	file, err := root.OpenFile(partPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if errors.Is(err, fs.ErrExist) {
		return UploadState{}, ErrUploadBeginUncertain
	}
	if err != nil {
		return UploadState{}, err
	}
	if err := s.syncFileContents(file); err != nil {
		_ = file.Close()
		if cleanupErr := errors.Join(root.Remove(partPath), syncUploadsRoot(s, root)); cleanupErr != nil {
			return UploadState{}, fmt.Errorf("%w: %v; rollback: %v", ErrUploadBeginUncertain, err, cleanupErr)
		}
		return UploadState{}, err
	}
	if err := file.Close(); err != nil {
		if cleanupErr := errors.Join(root.Remove(partPath), syncUploadsRoot(s, root)); cleanupErr != nil {
			return UploadState{}, fmt.Errorf("%w: %v; rollback: %v", ErrUploadBeginUncertain, err, cleanupErr)
		}
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
			return UploadState{}, fmt.Errorf("%w: begin failed: %v; rollback failed: %v", ErrUploadBeginUncertain, err, cleanupErr)
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

// A check and its bounded write share the same lock across upload streams
// and registered roots. A slow client waits outside the lock.
var uploadWriteMu sync.Mutex

const uploadReserveBytes int64 = 64 << 20

type uploadStreamWriter struct {
	store         *Store
	file          *os.File
	offset        int64
	count         int64
	limit         int64
	initialBudget int64
	probed        bool
}

func (w *uploadStreamWriter) Write(p []byte) (int, error) {
	size := int64(len(p))
	if size > w.limit-w.count {
		return 0, ErrSize
	}
	if size == 0 {
		return 0, nil
	}
	uploadWriteMu.Lock()
	defer uploadWriteMu.Unlock()
	freeBytes, err := w.store.availableUploadBytes(w.file)
	if err != nil {
		return 0, errors.Join(ErrInsufficientSpace, err)
	}
	available := max(0, freeBytes-uploadReserveBytes)
	if !w.probed {
		w.initialBudget = available
		w.probed = true
	}
	if size > available || size > w.initialBudget-w.count {
		return 0, ErrInsufficientSpace
	}
	n, err := w.file.WriteAt(p, w.offset+w.count)
	w.count += int64(n)
	if errors.Is(err, syscall.ENOSPC) {
		err = errors.Join(ErrInsufficientSpace, err)
	}
	return n, err
}

// Append accepts a bounded chunk at a sequential offset. Bytes are durable
// before the journal advances; every failed stream is truncated back to the
// committed prefix, including disconnections and an overlong request body.
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
	rollback := func() {
		if err := validateOpenedUploadPart(f, openedInfo, &initialIdentity); err != nil {
			return
		}
		_ = f.Truncate(offset)
		_ = s.syncFileContents(f)
	}
	limit := min(maxChunk, remaining)
	writer := &uploadStreamWriter{store: s, file: f, offset: offset, limit: limit}
	// LimitReader suppresses Reader.WriteTo fast paths that could otherwise
	// bypass the fixed transfer buffer. One extra byte detects oversized input.
	count, err := io.CopyBuffer(writer, io.LimitReader(source, limit+1), make([]byte, min(int64(uploadBufferSize), limit+1)))
	if err != nil {
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
	// A slow request can outlive an external rename of the staging entry.
	// Do not advance a journal that now names a different inode. Rollback only
	// touches our already-opened part, never the replacement pathname.
	currentInfo, err := root.Lstat(id + ".part")
	if err != nil || validatePrivateUploadPart(currentInfo) != nil || !os.SameFile(openedInfo, currentInfo) {
		rollback()
		_ = f.Close()
		return meta, ErrUploadCorrupt
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
