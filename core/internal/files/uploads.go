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
	ID      string `json:"id"`
	Path    string `json:"path"`
	Size    int64  `json:"size"`
	Offset  int64  `json:"offset"`
	Owner   int64  `json:"owner"`
	Created int64  `json:"created"`
}

var ErrOffset = errors.New("offset_mismatch")
var ErrOwner = errors.New("upload_owner_mismatch")
var uploadIDPattern = regexp.MustCompile("^[a-f0-9]{32}$")

// Uploads are rooted inside the selected share. Opening the same part from
// another root cannot complete a transfer into a different volume.
func (s *Store) ensureUploads() error {
	e := s.root.Mkdir(uploadsDir, 0700)
	if errors.Is(e, os.ErrExist) {
		return nil
	}
	return e
}
func (s *Store) uploadMeta(id string) (UploadState, error) {
	if !uploadIDPattern.MatchString(id) {
		return UploadState{}, ErrPath
	}
	data, err := s.root.ReadFile(path.Join(uploadsDir, id+".json"))
	if err != nil {
		return UploadState{}, err
	}
	var meta UploadState
	if err := json.Unmarshal(data, &meta); err != nil || meta.ID != id {
		return UploadState{}, ErrPath
	}
	fi, err := s.root.Stat(path.Join(uploadsDir, id+".part"))
	if err != nil {
		return UploadState{}, err
	}
	meta.Offset = fi.Size()
	if meta.Offset > meta.Size {
		return UploadState{}, ErrSize
	}
	return meta, nil
}
func (s *Store) BeginUpload(destination string, size, owner int64) (UploadState, error) {
	if size < 0 || size > maxResumableSize {
		return UploadState{}, ErrSize
	}
	name, err := validate(destination, false)
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
	meta := UploadState{ID: id, Path: name, Size: size, Owner: owner, Created: time.Now().Unix()}
	file, err := s.root.OpenFile(path.Join(uploadsDir, id+".part"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return UploadState{}, err
	}
	file.Close()
	data, _ := json.Marshal(meta)
	if err := s.root.WriteFile(path.Join(uploadsDir, id+".json"), data, 0600); err != nil {
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
		return meta, err
	}
	if err := f.Sync(); err != nil {
		return meta, err
	}
	meta.Offset += count
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
