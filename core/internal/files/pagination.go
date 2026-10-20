package files

import (
	"container/heap"
	"errors"
	"io"
	"io/fs"
	"os"
	"path"
	"sort"
	"strings"
)

type pageCandidate struct {
	name string
	info os.FileInfo
}

// pageHeap is a max-heap ordered by name. Page keeps at most limit+1
// candidates, so selection memory is bounded by the requested page rather
// than by the directory size.
type pageHeap []pageCandidate

func (h pageHeap) Len() int           { return len(h) }
func (h pageHeap) Less(i, j int) bool { return h[i].name > h[j].name }
func (h pageHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }

func (h *pageHeap) Push(x any) { *h = append(*h, x.(pageCandidate)) }

func (h *pageHeap) Pop() any {
	old := *h
	n := len(old)
	item := old[n-1]
	*h = old[:n-1]
	return item
}

// Page reads directory entries in bounded batches and retains only the
// smallest limit+1 visible names after the cursor. Cursor is the last file
// name (exclusive), so unrelated insertions don't skip earlier items.
// ReadDir order is unspecified, so a page may still require reading every
// name; the candidate set stays bounded by limit+1 and only names that can
// enter it are stat'ed.
//
// Symbolic links and unsupported entry types are intentionally omitted, and
// entries that disappear between readdir and stat are skipped. Every other
// stat failure is returned: silently dropping an entry on EIO or EACCES would
// make a client believe a page is complete while files are missing. Entries
// that sort after the retained candidates are never stat'ed, so a failure
// confined to them is not surfaced.
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
	capacity := limit + 1
	selected := make(pageHeap, 0, capacity)
	heap.Init(&selected)
	for {
		batch, readErr := dir.ReadDir(256)
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			return nil, "", readErr
		}
		for _, entry := range batch {
			name := entry.Name()
			if name <= after || strings.HasPrefix(name, ".lightisle-") {
				continue
			}
			// Once full, a name sorting after the largest retained candidate
			// cannot be part of this page, so its metadata is not needed.
			if len(selected) == capacity && name >= selected[0].name {
				continue
			}
			info, statErr := s.entryInfo(dir, name)
			if statErr != nil {
				if errors.Is(statErr, fs.ErrNotExist) || errors.Is(statErr, ErrType) {
					continue
				}
				return nil, "", statErr
			}
			if typeOf(info) == "unsupported" {
				continue
			}
			heap.Push(&selected, pageCandidate{name: name, info: info})
			if len(selected) > capacity {
				heap.Pop(&selected)
			}
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
	}
	candidates := make([]pageCandidate, len(selected))
	for i := range candidates {
		candidates[i] = heap.Pop(&selected).(pageCandidate)
	}
	sort.Slice(candidates, func(i, j int) bool { return candidates[i].name < candidates[j].name })
	more := len(candidates) > limit
	if more {
		candidates = candidates[:limit]
	}
	out := make([]Entry, 0, len(candidates))
	for _, candidate := range candidates {
		p := candidate.name
		if target != "." {
			p = path.Join(target, candidate.name)
		}
		out = append(out, Entry{
			Name:     candidate.name,
			Path:     p,
			Type:     typeOf(candidate.info),
			Size:     candidate.info.Size(),
			Modified: candidate.info.ModTime(),
		})
	}
	next := ""
	if more && len(out) > 0 {
		next = out[len(out)-1].Name
	}
	return out, next, nil
}
