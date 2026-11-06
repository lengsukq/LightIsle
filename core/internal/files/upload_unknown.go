package files

import (
	"context"
	"errors"
	"io"
	"sort"
)

// ListUnknownUploadEntries lists names that do not correspond to a recognized
// upload journal or part. It never follows, opens, modifies, or deletes the
// listed entry. Paging keeps memory bounded even when an external program has
// placed a large number of unexpected files in the staging directory.
func (m *Manager) ListUnknownUploadEntries(ctx context.Context, after string, limit int) (names []string, next string, err error) {
	if ctx == nil || len(after) > 1024 || limit < 1 || limit > 100 {
		return nil, "", ErrPath
	}
	// This is a read-only inventory. Do not block active uploads while a
	// potentially large directory is enumerated; detect concurrent name
	// changes and ask the administrator to retry instead.
	err = m.withRead(func(s *Store) error {
		root, _, err := s.openExistingUploadsRoot()
		if err != nil || root == nil {
			return err
		}
		dir, err := root.Open(".")
		if err != nil {
			return err
		}
		defer dir.Close()
		original, err := dir.Stat()
		if err != nil {
			return err
		}
		candidates := make([]string, 0, limit+1)
		for {
			if err := ctx.Err(); err != nil {
				return err
			}
			batch, readErr := dir.ReadDir(256)
			for _, entry := range batch {
				name := entry.Name()
				if _, ok := uploadIDFromName(name, ".json"); ok {
					continue
				}
				if _, ok := uploadIDFromName(name, ".part"); ok {
					continue
				}
				if name <= after {
					continue
				}
				position := sort.SearchStrings(candidates, name)
				if position > limit {
					continue
				}
				candidates = append(candidates, "")
				copy(candidates[position+1:], candidates[position:])
				candidates[position] = name
				if len(candidates) > limit+1 {
					candidates = candidates[:limit+1]
				}
			}
			if errors.Is(readErr, io.EOF) {
				break
			}
			if readErr != nil {
				return readErr
			}
			if len(batch) == 0 {
				return io.ErrNoProgress
			}
		}
		current, err := dir.Stat()
		if err != nil {
			return err
		}
		if !original.ModTime().Equal(current.ModTime()) {
			return ErrScanDirectoryChanged
		}
		if _, _, err := s.openExistingUploadsRoot(); err != nil {
			return err
		}
		if len(candidates) > limit {
			candidates = candidates[:limit]
			next = candidates[len(candidates)-1]
		}
		names = candidates
		return nil
	})
	return names, next, err
}
