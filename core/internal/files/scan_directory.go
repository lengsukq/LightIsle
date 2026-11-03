package files

import (
	"context"
	"errors"
	"io"
	"io/fs"
	"os"
	"path"
)

const scanDirectoryBatch = 200

// ScanDirectory visits each directory entry once in filesystem order. Media
// reconciliation does not need the sorted HTTP cursor API, which re-enumerates
// the directory for every page. Only one batch is retained. The callback runs
// outside the manager lock so media probing may safely read files through m.
// An interrupted or changed directory returns an error, never a clean EOF.
func (m *Manager) ScanDirectory(ctx context.Context, raw string, visit func([]Entry) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	release, ok := m.TryAcquireLegacyRequest()
	if !ok {
		return ErrRootBusy
	}
	defer release()
	var target string
	var dir *os.File
	var original os.FileInfo
	err := m.withRead(func(s *Store) (err error) {
		target, err = s.safePath(raw, true, false)
		if err != nil {
			return err
		}
		dir, err = s.openDirNoFollow(target)
		if err != nil {
			return err
		}
		original, err = dir.Stat()
		return err
	})
	if dir != nil {
		defer dir.Close()
	}
	if err != nil {
		return err
	}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		var entries []Entry
		var done bool
		err := m.withRead(func(s *Store) error {
			// Root identity is checked by withRead on every batch. Also pin
			// the selected subdirectory: a renamed/replaced path must not
			// silently be treated as a complete scan of its replacement.
			current, err := s.openDirNoFollow(target)
			if err != nil {
				return err
			}
			info, err := current.Stat()
			_ = current.Close()
			if err != nil {
				return err
			}
			if !os.SameFile(original, info) {
				return ErrPath
			}
			batch, err := dir.ReadDir(scanDirectoryBatch)
			if err != nil && !errors.Is(err, io.EOF) {
				return err
			}
			done = errors.Is(err, io.EOF)
			entries = make([]Entry, 0, len(batch))
			for _, entry := range batch {
				if err := ctx.Err(); err != nil {
					return err
				}
				name := entry.Name()
				if IsInternalName(name) {
					continue
				}
				info, err := s.entryInfo(dir, name)
				if errors.Is(err, fs.ErrNotExist) || errors.Is(err, ErrType) {
					continue
				}
				if err != nil {
					return err
				}
				kind := typeOf(info)
				if kind == "unsupported" {
					continue
				}
				entries = append(entries, Entry{Name: name, Path: path.Join(target, name), Type: kind, Size: info.Size(), Modified: info.ModTime()})
			}
			return nil
		})
		if err != nil {
			return err
		}
		if len(entries) > 0 {
			if err := visit(entries); err != nil {
				return err
			}
		}
		if done && len(entries) == 0 {
			return ctx.Err()
		}
	}
}
