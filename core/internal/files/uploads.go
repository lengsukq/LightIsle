package files

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
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
}

func (s *Store) AbortUpload(id string, owner int64) error {
	if _, err := s.UploadInfo(id, owner); err != nil {
		return err
	}
	if err := s.root.Remove(path.Join(uploadsDir, id+".part")); err != nil {
		return err
	}
	return s.root.Remove(path.Join(uploadsDir, id+".json"))
}

var ErrOffset = errors.New("offset_mismatch")
var ErrOwner = errors.New("upload_owner_mismatch")
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
	return e
}
func (s *Store) uploadMeta(id string) (UploadState, error) {
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
	partInfo, err := s.root.Lstat(path.Join(uploadsDir, id+".part"))
	if err != nil {
		return UploadState{}, err
	}
	if !partInfo.Mode().IsRegular() {
		return UploadState{}, ErrType
	}
	var meta UploadState
	if err := json.Unmarshal(data, &meta); err != nil || meta.ID != id {
		return UploadState{}, ErrPath
	}
	fi, err := s.root.Stat(path.Join(uploadsDir, id+".part"))
	if err != nil {
		return UploadState{}, err
	}
	if meta.Version < 2 {
		// Migration from v1, where each completed chunk was synced and
		// the file length, not JSON, tracked the upload offset.
		meta.Offset = fi.Size()
		meta.Version = 2
		if err := s.persistUpload(meta); err != nil {
			return UploadState{}, err
		}
	}
	if meta.Offset < 0 || fi.Size() < meta.Offset || meta.Offset > meta.Size {
		return UploadState{}, ErrSize
	}
	if fi.Size() > meta.Offset {
		// Crash after data write but before metadata commit. Ignore all
		// uncommitted trailing bytes instead of publishing corrupt data.
		part, err := s.root.OpenFile(path.Join(uploadsDir, id+".part"), os.O_RDWR, 0600)
		if err != nil {
			return UploadState{}, err
		}
		err = part.Truncate(meta.Offset)
		if err == nil {
			err = part.Sync()
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
// corresponding part bytes have been flushed. This is the recovery journal.
func (s *Store) persistUpload(meta UploadState) error {
	data, err := json.Marshal(meta)
	if err != nil {
		return err
	}
	tmp := path.Join(uploadsDir, ".lightisle-uploadmeta-"+randomName())
	f, err := s.root.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer s.root.Remove(tmp)
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return s.root.Rename(tmp, path.Join(uploadsDir, meta.ID+".json"))
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
	} else if !errors.Is(err, os.ErrNotExist) {
		return UploadState{}, err
	}
	if err := s.ensureUploads(); err != nil {
		return UploadState{}, err
	}
	id := randomName()
	meta := UploadState{Version: 2, ID: id, Path: name, Size: size, Owner: owner, Created: time.Now().Unix()}
	file, err := s.root.OpenFile(path.Join(uploadsDir, id+".part"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return UploadState{}, err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		s.root.Remove(path.Join(uploadsDir, id+".part"))
		return UploadState{}, err
	}
	if err := file.Close(); err != nil {
		s.root.Remove(path.Join(uploadsDir, id+".part"))
		return UploadState{}, err
	}
	if err := s.persistUpload(meta); err != nil {
		_ = s.root.Remove(path.Join(uploadsDir, id+".part"))
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
	if offset != meta.Offset {
		return meta, ErrOffset
	}
	remaining := meta.Size - offset
	if remaining < 0 {
		return meta, ErrOffset
	}
	f, err := s.root.OpenFile(path.Join(uploadsDir, id+".part"), os.O_WRONLY, 0600)
	if err != nil {
		return meta, err
	}
	defer f.Close()
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return meta, err
	}
	data, err := io.ReadAll(io.LimitReader(source, maxChunk+1))
	if err != nil {
		return meta, err
	}
	count := int64(len(data))
	if count > maxChunk || count > remaining {
		return meta, ErrSize
	}
	if _, err := io.Copy(f, bytes.NewReader(data)); err != nil {
		_ = f.Truncate(meta.Offset)
		return meta, err
	}
	if err := f.Sync(); err != nil {
		_ = f.Truncate(meta.Offset)
		return meta, err
	}
	meta.Offset += count
	if err := s.persistUpload(meta); err != nil {
		_ = f.Truncate(offset)
		_ = f.Sync()
		return UploadState{}, err
	}
	return meta, nil
}
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
	// Commit atomically without replacing a file that another client created.
	if err := s.root.Link(path.Join(uploadsDir, id+".part"), meta.Path); err != nil {
		if errors.Is(err, os.ErrExist) {
			return ErrExists
		}
		return err
	}
	_ = s.root.Remove(path.Join(uploadsDir, id+".part"))
	return s.root.Remove(path.Join(uploadsDir, id+".json"))
}
