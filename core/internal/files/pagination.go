package files

import (
	"errors"
	"io"
	"os"
	"path"
	"sort"
)

// Page reads directory entries in bounded batches; it retains only
// the next page rather than the entire directory. Cursor is the last
// file name (exclusive), so unrelated insertions don't skip earlier items.
func (s *Store) Page(raw, after string, limit int) ([]Entry, string, error) {
	target, err := s.safePath(raw, true, false)
	if err != nil {
		return nil, "", err
	}
	if limit < 1 || limit > 200 {
		return nil, "", ErrPath
	}
	if after != "" {
		if _, err := validate(after, false); err != nil {
			return nil, "", err
		}
		if path.Base(after) != after {
			return nil, "", ErrPath
		}
	}
	dir, err := s.openDirNoFollow(target)
	if err != nil {
		return nil, "", err
	}
	defer dir.Close()
	stat, err := dir.Stat()
	if err != nil {
		return nil, "", err
	}
	if !stat.IsDir() {
		return nil, "", ErrType
	}
	// Bounded selection: at most limit+1 visible candidates.
	chosen := make([]os.DirEntry, 0, limit+1)
	for {
		batch, e := dir.ReadDir(256)
		if e != nil && !errors.Is(e, io.EOF) {
			return nil, "", e
		}
		for _, entry := range batch {
			name := entry.Name()
			if name <= after || len(name) >= 10 && name[:10] == ".lightisle" {
				continue
			}
			if _, e := statEntryNoFollow(dir, name); e != nil {
				continue
			}
			chosen = append(chosen, entry)
			if len(chosen) > limit+1 {
				sort.Slice(chosen, func(i, j int) bool { return chosen[i].Name() < chosen[j].Name() })
				chosen = chosen[:limit+1]
			}
		}
		if errors.Is(e, io.EOF) {
			break
		}
	}
	sort.Slice(chosen, func(i, j int) bool { return chosen[i].Name() < chosen[j].Name() })
	more := len(chosen) > limit
	if more {
		chosen = chosen[:limit]
	}
	out := make([]Entry, 0, len(chosen))
	for _, entry := range chosen {
		fi, e := statEntryNoFollow(dir, entry.Name())
		if e != nil {
			continue
		}
		kind := typeOf(fi)
		if kind == "unsupported" {
			continue
		}
		p := entry.Name()
		if target != "." {
			p = path.Join(target, p)
		}
		out = append(out, Entry{Name: entry.Name(), Path: p, Type: kind, Size: fi.Size(), Modified: fi.ModTime()})
	}
	next := ""
	if more && len(out) > 0 {
		next = out[len(out)-1].Name
	}
	return out, next, nil
}
