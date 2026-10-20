package files

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path"
	"strings"
)

// Move performs a same-share rename, refusing to replace existing user data.
// External processes can alter the shared folder concurrently; the manager
// serializes LightIsle operations but this is not a filesystem transaction.
func (s *Store) Move(from, to string) error {
	src, err := s.safePath(from, false, false)
	if err != nil {
		return err
	}
	dst, err := s.safePath(to, false, true)
	if err != nil {
		return err
	}
	if src == dst {
		return ErrExists
	}
	if strings.HasPrefix(dst, src+"/") {
		return ErrPath
	}
	info, err := s.root.Lstat(src)
	if err != nil {
		return err
	}
	if !info.IsDir() && !info.Mode().IsRegular() {
		return ErrType
	}
	if _, err = s.root.Lstat(dst); err == nil {
		return ErrExists
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	parent, err := s.root.Stat(path.Dir(dst))
	if err != nil {
		return err
	}
	if !parent.IsDir() {
		return ErrType
	}
	// A single Darwin RENAME_EXCL atomically moves files *and directories*
	// without a hard-link/remove gap or replacing an empty destination folder.
	// Across filesystems the syscall returns EXDEV and the source remains intact.
	return s.renameExclusive(src, dst)
}

// Copy allows individual regular files only. Directory and cross-volume copy
// require a separate recoverable job and are intentionally rejected for now.
func (s *Store) Copy(from, to string) error {
	return s.CopyContext(context.Background(), from, to)
}
func (s *Store) CopyContext(ctx context.Context, from, to string) error {
	src, err := s.safePath(from, false, false)
	if err != nil {
		return err
	}
	dst, err := s.safePath(to, false, true)
	if err != nil {
		return err
	}
	if src == dst {
		return ErrExists
	}
	if strings.HasPrefix(dst, src+"/") {
		return ErrPath
	}
	info, err := s.root.Lstat(src)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return s.copyDirectory(ctx, src, dst)
	}
	if !info.Mode().IsRegular() {
		return ErrType
	}
	return s.copyRegular(ctx, src, dst)
}
func (s *Store) copyRegular(ctx context.Context, src, dst string) error {
	f, info, err := s.Read(src)
	if err != nil {
		return err
	}
	defer f.Close()
	if info.Size() > 32<<30 {
		return ErrSize
	}
	if _, err = s.root.Lstat(dst); err == nil {
		return ErrExists
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	parent, err := s.root.Stat(path.Dir(dst))
	if err != nil {
		return err
	}
	if !parent.IsDir() {
		return ErrType
	}
	tmp := path.Join(path.Dir(dst), ".lightisle-copy-"+randomName())
	out, err := s.root.OpenFile(tmp, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	defer s.root.Remove(tmp)
	copyErr := copyVerified(ctx, out, f, info.Size())
	closeErr := out.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	return s.renameExclusive(tmp, dst)
}

// Purge is intentionally restricted to an already trashed item. Live files
// cannot be irreversibly removed by this API.
func (s *Store) Purge(id string) error {
	if !trashIDRule.MatchString(id) {
		return ErrPath
	}
	if _, err := s.root.Lstat(path.Join(Trash, id+".json")); err != nil {
		return err
	}
	if err := s.root.RemoveAll(path.Join(Trash, id)); err != nil {
		return err
	}
	return s.root.Remove(path.Join(Trash, id+".json"))
}

// Search is an on-demand bounded search of visible file names. It avoids
// symlinks and limits visited entries to protect CPU and disk resources.
func (s *Store) Search(base, term string, limit int) ([]Entry, bool, error) {
	base, err := validate(base, true)
	if err != nil {
		return nil, false, err
	}
	term = strings.TrimSpace(term)
	if len(term) < 2 || len(term) > 128 || limit < 1 || limit > 200 {
		return nil, false, ErrPath
	}
	term = strings.ToLower(term)
	queue := []string{base}
	result := []Entry{}
	visited := 0
	for len(queue) > 0 && visited < 30000 && len(result) < limit {
		dir := queue[len(queue)-1]
		queue = queue[:len(queue)-1]
		cursor := ""
		for {
			entries, next, e := s.Page(dir, cursor, 200)
			if e != nil {
				return nil, false, e
			}
			for _, entry := range entries {
				visited++
				if strings.Contains(strings.ToLower(entry.Name), term) {
					result = append(result, entry)
					if len(result) >= limit {
						break
					}
				}
				if entry.Type == "folder" {
					queue = append(queue, entry.Path)
				}
				if visited >= 30000 {
					break
				}
			}
			if next == "" || visited >= 30000 || len(result) >= limit {
				break
			}
			cursor = next
		}
	}
	return result, len(queue) > 0 || visited >= 30000 || len(result) >= limit, nil
}
