package files

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// CopyOut copies a file or entire directory from the configured share to a
// *Mac-owner-selected* destination directory. This operation is deliberately
// absent from HTTP; the native app must obtain the source/destination through
// macOS file pickers. It never deletes the source or replaces existing data.
//
// All copied bytes are staged on the destination filesystem, fsynced and
// verified against the source prior to one exclusive RENAME_EXCL publication.
// A hard crash may leave a hidden .lightisle-transfer-* stage, but will not
// expose a partially copied final destination.
func (m *Manager) CopyOut(ctx context.Context, sourceRelative, destinationDir string) (string, error) {
	m.opMu.Lock()
	defer m.opMu.Unlock()
	var result string
	err := m.withRead(func(s *Store) error {
		var e error
		result, e = s.CopyOut(ctx, sourceRelative, destinationDir)
		return e
	})
	return result, err
}

func (s *Store) CopyOut(ctx context.Context, sourceRelative, destinationDir string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	src, err := s.safePath(sourceRelative, false, false)
	if err != nil {
		return "", err
	}
	info, err := s.root.Lstat(src)
	if err != nil {
		return "", err
	}
	if !info.IsDir() && !info.Mode().IsRegular() {
		return "", ErrType
	}
	// Keep the selected export path inside the Mac user's own home or in a
	// real external /Volumes location. Symlink targets are canonicalized.
	destination, err := allowedSelectedFolder(destinationDir)
	if err != nil {
		return "", err
	}
	share, err := filepath.EvalSymlinks(s.root.Name())
	if err != nil {
		return "", ErrOffline
	}
	if pathsOverlap(share, destination) {
		return "", ErrPath
	}
	outRoot, err := os.OpenRoot(destination)
	if err != nil {
		return "", err
	}
	defer outRoot.Close()
	start, err := outRoot.Stat(".")
	if err != nil {
		return "", err
	}
	target := path.Base(src)
	if _, err := validate(target, false); err != nil {
		return "", err
	}
	if _, err := outRoot.Lstat(target); err == nil {
		return "", ErrExists
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	stage := ".lightisle-transfer-" + randomName()
	if info.IsDir() {
		if err := outRoot.Mkdir(stage, 0700); err != nil {
			return "", err
		}
	} else {
		// Do not open a real destination file name until validation finishes.
		f, err := outRoot.OpenFile(stage, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
		if err != nil {
			return "", err
		}
		if err := f.Close(); err != nil {
			_ = outRoot.Remove(stage)
			return "", err
		}
	}
	defer outRoot.RemoveAll(stage)

	if info.IsDir() {
		err = s.copyOutTree(ctx, src, outRoot, stage)
	} else {
		var input *os.File
		input, err = s.openFileNoFollow(src)
		if err == nil {
			var output *os.File
			output, err = outRoot.OpenFile(stage, os.O_RDWR, 0600)
			if err == nil {
				err = copyVerified(ctx, output, input, info.Size())
				if closeErr := output.Close(); err == nil {
					err = closeErr
				}
			}
			if closeErr := input.Close(); err == nil {
				err = closeErr
			}
		}
	}
	if err != nil {
		return "", err
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	// Prevent publishing on a different disk mounted at the same path.
	current, err := os.Stat(destination)
	if err != nil || !os.SameFile(current, start) {
		return "", ErrOffline
	}
	current, err = os.Stat(share)
	original, rootErr := s.root.Stat(".")
	if err != nil || rootErr != nil || !os.SameFile(current, original) {
		return "", ErrOffline
	}
	// Use a held target directory descriptor; existing files AND directories
	// cannot be replaced, including against concurrent Finder operations.
	fd, err := outRoot.Open(".")
	if err != nil {
		return "", err
	}
	defer fd.Close()
	if err := unix.RenameatxNp(int(fd.Fd()), stage, int(fd.Fd()), target, unix.RENAME_EXCL); err != nil {
		if errors.Is(err, os.ErrExist) {
			return "", ErrExists
		}
		return "", err
	}
	// Once the directory entry is durable, success may safely be reported.
	if err := fd.Sync(); err != nil {
		return filepath.Join(destination, target), fmt.Errorf("export_published_but_directory_sync_failed: %w", err)
	}
	return filepath.Join(destination, target), nil
}

func pathsOverlap(a, b string) bool {
	inside := func(parent, candidate string) bool {
		rel, err := filepath.Rel(parent, candidate)
		return err == nil && (rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))))
	}
	return inside(a, b) || inside(b, a)
}

func (s *Store) copyOutTree(ctx context.Context, src string, dest *os.Root, stage string) error {
	output, err := dest.OpenRoot(stage)
	if err != nil {
		return err
	}
	defer output.Close()
	queue := []string{"."}
	entries := 0
	var bytesTotal int64
	for len(queue) != 0 {
		if err := ctx.Err(); err != nil {
			return err
		}
		rel := queue[len(queue)-1]
		queue = queue[:len(queue)-1]
		input, err := s.openDirNoFollow(path.Join(src, rel))
		if err != nil {
			return err
		}
		before, err := input.Stat()
		if err != nil {
			input.Close()
			return err
		}
		for {
			if err := ctx.Err(); err != nil {
				input.Close()
				return err
			}
			batch, readErr := input.ReadDir(128)
			if readErr != nil && !errors.Is(readErr, io.EOF) {
				input.Close()
				return readErr
			}
			for _, entry := range batch {
				name := entry.Name()
				child := name
				if rel != "." {
					child = path.Join(rel, name)
				}
				if _, err := validate(child, false); err != nil {
					input.Close()
					return err
				}
				stat, err := statEntryNoFollow(input, name)
				if err != nil {
					input.Close()
					return err
				}
				entries++
				if entries > maxCopyEntries {
					input.Close()
					return ErrSize
				}
				if stat.IsDir() {
					if err := output.Mkdir(child, 0700); err != nil {
						input.Close()
						return err
					}
					queue = append(queue, child)
					continue
				}
				if !stat.Mode().IsRegular() {
					input.Close()
					return ErrType
				}
				if stat.Size() > maxCopyBytes-bytesTotal {
					input.Close()
					return ErrSize
				}
				bytesTotal += stat.Size()
				source, err := s.openFileNoFollow(path.Join(src, child))
				if err != nil {
					input.Close()
					return err
				}
				destFile, err := output.OpenFile(child, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
				if err == nil {
					err = copyVerified(ctx, destFile, source, stat.Size())
					if e := destFile.Close(); err == nil {
						err = e
					}
				}
				if e := source.Close(); err == nil {
					err = e
				}
				if err != nil {
					input.Close()
					return err
				}
			}
			if errors.Is(readErr, io.EOF) {
				break
			}
		}
		after, err := input.Stat()
		input.Close()
		if err != nil {
			return err
		}
		if !os.SameFile(before, after) || !before.ModTime().Equal(after.ModTime()) {
			return errors.New("source_directory_changed_during_copy")
		}
	}
	// Files and directory entries must be persisted before publication.
	return syncTree(ctx, output, ".")
}

func syncTree(ctx context.Context, root *os.Root, dir string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	f, err := root.Open(dir)
	if err != nil {
		return err
	}
	items, err := f.ReadDir(-1)
	if err != nil {
		f.Close()
		return err
	}
	for _, item := range items {
		if item.IsDir() {
			if err := syncTree(ctx, root, path.Join(dir, item.Name())); err != nil {
				f.Close()
				return err
			}
		}
	}
	err = f.Sync()
	if e := f.Close(); err == nil {
		err = e
	}
	return err
}
