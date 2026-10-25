package files

import (
	"container/heap"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"sort"
	"strconv"
	"strings"
)

// SortKey selects the primary ordering for PageSorted. The plain name sort
// keeps the original cursor protocol; size and mtime use a composite cursor.
type SortKey string

const (
	SortName     SortKey = "name"
	SortSize     SortKey = "size"
	SortModified SortKey = "mtime"
)

// sortCursorKeyDigits is the fixed width of the encoded primary key inside a
// composite cursor ("NNNNNNNNNNNNNNNNNNNNname"). A fixed width keeps parsing
// unambiguous because file names may contain any byte accepted by validate.
const sortCursorKeyDigits = 20

type pageCandidate struct {
	name string
	info os.FileInfo
}

// sortCandidate carries the encoded primary key so heap comparisons never
// recompute it. For the plain name sort primary is empty and only the name
// is compared.
type sortCandidate struct {
	pageCandidate
	primary string
}

// desiredLess reports whether a sorts strictly before b under the requested
// ordering. The name is always the tiebreaker so the order is total.
func desiredLess(key SortKey, desc bool, a, b sortCandidate) bool {
	if key == SortName {
		if desc {
			return a.name > b.name
		}
		return a.name < b.name
	}
	if a.primary != b.primary {
		if desc {
			return a.primary > b.primary
		}
		return a.primary < b.primary
	}
	if desc {
		return a.name > b.name
	}
	return a.name < b.name
}

// candidateExcluded reports whether a candidate sorts at or before the
// cursor (exclusive), so it cannot belong to this or any later page.
func candidateExcluded(key SortKey, desc bool, c sortCandidate, cursor sortCandidate) bool {
	if cursor.name == "" && cursor.primary == "" {
		return false // no cursor: the first page starts at the extreme
	}
	if key == SortName {
		if desc {
			return c.name >= cursor.name
		}
		return c.name <= cursor.name
	}
	if c.primary != cursor.primary {
		if desc {
			return c.primary >= cursor.primary
		}
		return c.primary <= cursor.primary
	}
	if desc {
		return c.name >= cursor.name
	}
	return c.name <= cursor.name
}

// sortHeap is a bounded heap whose top is the worst candidate under the
// requested ordering; pushing beyond capacity evicts that top.
type sortHeap struct {
	items []sortCandidate
	key   SortKey
	desc  bool
}

func (h sortHeap) Len() int { return len(h.items) }

// Less keeps the worst candidate on top: container/heap is a min-heap on
// Less, so Less(i,j) must report "item i is worse than item j".
func (h sortHeap) Less(i, j int) bool { return desiredLess(h.key, h.desc, h.items[j], h.items[i]) }
func (h sortHeap) Swap(i, j int)      { h.items[i], h.items[j] = h.items[j], h.items[i] }

func heapInit(h *sortHeap) { heap.Init(h) }

func heapPush(h *sortHeap, c sortCandidate) { heap.Push(h, c) }

// heapPopWorst removes and returns the worst-ranked candidate (the heap top).
func heapPopWorst(h *sortHeap) sortCandidate { return heap.Pop(h).(sortCandidate) }

func (h *sortHeap) Push(x any) { h.items = append(h.items, x.(sortCandidate)) }

func (h *sortHeap) Pop() any {
	old := h.items
	n := len(old)
	item := old[n-1]
	h.items = old[:n-1]
	return item
}

func encodeSortPrimary(key SortKey, info os.FileInfo) (string, error) {
	switch key {
	case SortSize:
		size := info.Size()
		if size < 0 {
			size = 0
		}
		return fmt.Sprintf("%020d", uint64(size)), nil
	case SortModified:
		nano := info.ModTime().UnixNano()
		return fmt.Sprintf("%020d", uint64(nano)+(uint64(1)<<63)), nil
	default:
		return "", fmt.Errorf("sort key %q has no primary encoding", key)
	}
}

// EncodeSortCursor builds the opaque cursor for the entry that would come
// last in the current page. Name sorts return the bare name (the original
// protocol); composite sorts prefix the fixed-width primary key.
func EncodeSortCursor(key SortKey, name string, info os.FileInfo) (string, error) {
	if key == SortName {
		return name, nil
	}
	primary, err := encodeSortPrimary(key, info)
	if err != nil {
		return "", err
	}
	return primary + name, nil
}

// parseSortCursor splits a cursor produced by EncodeSortCursor. Name-sort
// cursors validate as file names exactly like before, so older clients keep
// working.
func parseSortCursor(key SortKey, desc bool, after string) (sortCandidate, error) {
	if key == SortName {
		if after != "" {
			if _, err := validate(after, false); err != nil {
				return sortCandidate{}, err
			}
			if path.Base(after) != after {
				return sortCandidate{}, ErrPath
			}
		}
		return sortCandidate{pageCandidate: pageCandidate{name: after}}, nil
	}
	if after == "" {
		return sortCandidate{}, nil
	}
	if len(after) <= sortCursorKeyDigits {
		return sortCandidate{}, ErrPath
	}
	primary, name := after[:sortCursorKeyDigits], after[sortCursorKeyDigits:]
	if _, err := strconv.ParseUint(primary, 10, 64); err != nil {
		return sortCandidate{}, ErrPath
	}
	if _, err := validate(name, false); err != nil {
		return sortCandidate{}, err
	}
	if path.Base(name) != name {
		return sortCandidate{}, ErrPath
	}
	return sortCandidate{pageCandidate: pageCandidate{name: name}, primary: primary}, nil
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
	return s.PageSorted(raw, after, limit, SortName, false)
}

// PageSorted is the general form of Page. Non-name orderings must stat every
// visible entry because the primary key lives in the metadata, so the
// pre-stat pruning shortcuts of the name sort no longer apply; the candidate
// set stays bounded by limit+1 either way. Composite cursors
// ("<20-digit primary key><name>") keep paging stable across insertions.
func (s *Store) PageSorted(raw, after string, limit int, key SortKey, desc bool) ([]Entry, string, error) {
	if key != SortName && key != SortSize && key != SortModified {
		return nil, "", ErrPath
	}
	target, err := s.safePath(raw, true, false)
	if err != nil {
		return nil, "", err
	}
	if limit < 1 || limit > 200 {
		return nil, "", ErrPath
	}
	cursor, err := parseSortCursor(key, desc, after)
	if err != nil {
		return nil, "", err
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
	selected := &sortHeap{items: make([]sortCandidate, 0, capacity), key: key, desc: desc}
	heapInit(selected)
	nameSorted := key == SortName && !desc
	for {
		batch, readErr := dir.ReadDir(256)
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			return nil, "", readErr
		}
		for _, entry := range batch {
			name := entry.Name()
			if strings.HasPrefix(name, ".lightisle-") {
				continue
			}
			if nameSorted {
				// Only the name sort can prune before stat'ing: the key is
				// the name itself.
				if name <= cursor.name {
					continue
				}
				if len(selected.items) == capacity && name >= selected.items[0].name {
					continue
				}
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
			candidate := sortCandidate{pageCandidate: pageCandidate{name: name, info: info}}
			if key != SortName {
				primary, encodeErr := encodeSortPrimary(key, info)
				if encodeErr != nil {
					return nil, "", encodeErr
				}
				candidate.primary = primary
			}
			if candidateExcluded(key, desc, candidate, cursor) {
				continue
			}
			heapPush(selected, candidate)
			if len(selected.items) > capacity {
				heapPopWorst(selected)
			}
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
	}
	candidates := make([]sortCandidate, len(selected.items))
	for i := range candidates {
		candidates[i] = heapPopWorst(selected)
	}
	sort.Slice(candidates, func(i, j int) bool { return desiredLess(key, desc, candidates[i], candidates[j]) })
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
		last := candidates[len(candidates)-1]
		next, err = EncodeSortCursor(key, last.name, last.info)
		if err != nil {
			return nil, "", err
		}
	}
	return out, next, nil
}
