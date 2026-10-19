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

var trashIDRule = regexp.MustCompile(`^[0-9a-f]{32}$`)

type TrashEntry struct {
	ID           string    `json:"id"`
	OriginalPath string    `json:"originalPath"`
	Name         string    `json:"name"`
	DeletedAt    time.Time `json:"deletedAt"`
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

func (s *Store) Restore(id string) error {
	if !trashIDRule.MatchString(id) {
		return ErrPath
	}
	metaName := path.Join(Trash, id+".json")
	data, err := s.root.ReadFile(metaName)
	if err != nil {
		return err
	}
	var entry TrashEntry
	if json.Unmarshal(data, &entry) != nil || entry.ID != id {
		return ErrPath
	}
	name, err := validate(entry.OriginalPath, false)
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
	if err := s.root.Rename(path.Join(Trash, id), name); err != nil {
		return err
	}
	return s.root.Remove(metaName)
}

type Store struct{ root *os.Root }

func Open(folder string) (*Store, error) {
	if err := os.MkdirAll(folder, 0700); err != nil {
		return nil, err
	}
	// Do not chmod existing data folders selected by the Mac owner.
	r, err := os.OpenRoot(folder)
	if err != nil {
		return nil, err
	}
	if err := r.Mkdir(Trash, 0700); err != nil && !errors.Is(err, fs.ErrExist) {
		r.Close()
		return nil, err
	}
	return &Store{root: r}, nil
}
func (s *Store) Close() error { return s.root.Close() }
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
	target, err := validate(raw, true)
	if err != nil {
		return nil, err
	}
	dir, err := s.root.Open(target)
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
		fi, err := item.Info()
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
	name, err := validate(raw, false)
	if err != nil {
		return nil, nil, err
	}
	f, err := s.root.Open(name)
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
	name, err := validate(raw, false)
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
	return s.root.Mkdir(name, 0700)
}
func randomName() string {
	var buf [16]byte
	_, _ = rand.Read(buf[:])
	return hex.EncodeToString(buf[:])
}

// Upload is streamed into a random temporary file inside the target directory.
// A hard link commits only if the destination does not exist, avoiding overwrite
// of existing user files. Temporary file is removed on all failed writes.
func (s *Store) Upload(raw string, source io.Reader) (int64, error) {
	name, err := validate(raw, false)
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
	defer s.root.Remove(tmp)
	n, err := io.Copy(f, io.LimitReader(source, maxUpload+1))
	closeErr := f.Close()
	if err != nil {
		return n, err
	}
	if closeErr != nil {
		return n, closeErr
	}
	if n > maxUpload {
		return n, ErrSize
	}
	if err := s.root.Link(tmp, name); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return 0, ErrExists
		}
		return 0, err
	}
	return n, nil
}

// Trash never permanently deletes user content. Internal items are not
// accessible through public APIs and deletion requires an authenticated user.
func (s *Store) MoveToTrash(raw string) error {
	name, err := validate(raw, false)
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
	data, err := json.Marshal(entry)
	if err != nil {
		return err
	}
	if err := s.root.Rename(name, dst); err != nil {
		return err
	}
	if err := s.root.WriteFile(path.Join(Trash, id+".json"), data, 0600); err != nil {
		if undoErr := s.root.Rename(dst, name); undoErr != nil {
			return fmt.Errorf("trash metadata write: %w; rollback: %v", err, undoErr)
		}
		return err
	}
	return nil
}
