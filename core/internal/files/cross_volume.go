package files

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/storageidentity"
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
	return s.copyOutWithTask(ctx, sourceRelative, destinationDir, nil, nil, nil)
}

func (s *Store) copyOutWithTask(ctx context.Context, sourceRelative, destinationDir string, task *TransferTask, identity storageidentity.Provider, progress transferProgressFunc) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	src, err := s.safePath(sourceRelative, false, false)
	if err != nil {
		return "", err
	}
	if task != nil {
		if err := verifyTaskRoots(ctx, s, *task, identity); err != nil {
			return "", err
		}
		snapshot, total, err := s.captureTransferSource(src)
		if err != nil {
			return "", err
		}
		if snapshot != task.SourceSnapshot || total != task.TotalBytes {
			return "", errors.New("queued_source_changed")
		}
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
	if task != nil {
		observed, err := identity.Capture(ctx, destination)
		current, statErr := os.Stat(destination)
		if err != nil || !storageidentity.Equal(observed, task.DestinationRoot) || statErr != nil || !os.SameFile(start, current) {
			return "", errors.New("queued_destination_root_identity_changed")
		}
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
		total := info.Size()
		if task != nil {
			total = task.TotalBytes
		}
		err = s.copyOutTreeWithProgress(ctx, src, outRoot, stage, total, progress)
	} else {
		var input *os.File
		input, err = s.openFileNoFollow(src)
		if err == nil {
			var output *os.File
			output, err = outRoot.OpenFile(stage, os.O_RDWR, 0600)
			if err == nil {
				if progress != nil {
					err = progress("copying", 0, info.Size())
				}
				if err == nil {
					report := func(n int64) error { return nil }
					if progress != nil {
						report = func(n int64) error { return progress("copying", n, info.Size()) }
					}
					err = copyVerifiedWithProgress(ctx, output, input, info.Size(), report)
				}
				if err == nil && progress != nil {
					err = progress("verifying", info.Size(), info.Size())
				}
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
	if task != nil {
		snapshot, total, err := s.captureTransferSource(src)
		if err != nil {
			return "", fmt.Errorf("queued_source_recheck_before_publish: %w", err)
		}
		if snapshot != task.SourceSnapshot || total != task.TotalBytes {
			return "", errors.New("queued_source_changed_before_publish")
		}
		if err := verifyTaskRoots(ctx, s, *task, identity); err != nil {
			return "", fmt.Errorf("queued_roots_changed_before_publish: %w", err)
		}
		observed, verifyErr := identity.Capture(ctx, destination)
		current, statErr := os.Stat(destination)
		pinned, pinnedErr := outRoot.Stat(".")
		if verifyErr != nil || !storageidentity.Equal(observed, task.DestinationRoot) || statErr != nil || pinnedErr != nil || !os.SameFile(pinned, current) {
			return "", errors.New("queued_destination_root_identity_changed_before_publish")
		}
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

func captureStoreRootIdentity(ctx context.Context, root *os.Root, identity storageidentity.Provider) (storageidentity.Binding, error) {
	if root == nil || identity == nil {
		return storageidentity.Binding{}, ErrOffline
	}
	binding, err := identity.Capture(ctx, root.Name())
	if err != nil {
		return storageidentity.Binding{}, err
	}
	resolved, err := filepath.EvalSymlinks(root.Name())
	if err != nil || resolved != binding.Path {
		return storageidentity.Binding{}, ErrOffline
	}
	opened, err := root.Stat(".")
	if err != nil || !opened.IsDir() {
		return storageidentity.Binding{}, ErrOffline
	}
	current, err := os.Stat(binding.Path)
	if err != nil || !os.SameFile(opened, current) {
		return storageidentity.Binding{}, ErrOffline
	}
	return binding, nil
}

func verifyTaskRoots(ctx context.Context, s *Store, task TransferTask, identity storageidentity.Provider) error {
	root, err := captureStoreRootIdentity(ctx, s.root, identity)
	if err != nil || !storageidentity.Equal(root, task.SourceRoot) {
		return errors.New("queued_source_root_identity_changed")
	}
	destination, err := identity.Capture(ctx, task.Destination)
	if err != nil || !storageidentity.Equal(destination, task.DestinationRoot) {
		return errors.New("queued_destination_root_identity_changed")
	}
	if root.VolumeUUID == destination.VolumeUUID {
		return ErrPath
	}
	return nil
}

// captureTransferSource stores a bounded metadata snapshot of the selected
// file/tree. It binds queued work to the same member names and inodes without
// reading a potentially multi-gigabyte tree just to enqueue it.
func (s *Store) captureTransferSource(source string) (string, int64, error) {
	name, err := s.safePath(source, false, false)
	if err != nil {
		return "", 0, err
	}
	rootInfo, err := s.root.Lstat(name)
	if err != nil {
		return "", 0, err
	}
	if !rootInfo.IsDir() && !rootInfo.Mode().IsRegular() {
		return "", 0, ErrType
	}
	records := make([]string, 0, 64)
	var total int64
	add := func(rel string, info os.FileInfo) error {
		if info.Size() < 0 {
			return ErrSize
		}
		if !info.IsDir() {
			if total > maxCopyBytes-info.Size() {
				return ErrSize
			}
			total += info.Size()
		}
		dev, inode, birthSec, birthNsec, generation, ok := transferFileInfoIdentity(info)
		if !ok {
			return ErrOffline
		}
		records = append(records, fmt.Sprintf("%q|%t|%o|%d|%d|%d|%d|%d|%d|%d", rel, info.IsDir(),
			info.Mode().Perm(), info.Size(), info.ModTime().UnixNano(), dev, inode, birthSec, birthNsec, generation))
		return nil
	}
	if err := add(".", rootInfo); err != nil {
		return "", 0, err
	}
	if !rootInfo.IsDir() {
		file, err := s.openFileNoFollow(name)
		if err != nil {
			return "", 0, err
		}
		opened, statErr := file.Stat()
		closeErr := file.Close()
		if statErr != nil || closeErr != nil || !sameTransferFile(opened, rootInfo) {
			return "", 0, errors.New("queued_source_changed_during_snapshot")
		}
	} else {
		type pendingDirectory struct{ rel string }
		queue := []pendingDirectory{{rel: "."}}
		entries := 0
		for len(queue) > 0 {
			current := queue[0]
			queue = queue[1:]
			rootName := name
			if current.rel != "." {
				rootName = path.Join(name, current.rel)
			}
			dir, err := s.openDirNoFollow(rootName)
			if err != nil {
				return "", 0, err
			}
			before, err := dir.Stat()
			if err != nil {
				dir.Close()
				return "", 0, err
			}
			for {
				batch, readErr := dir.ReadDir(128)
				if readErr != nil && !errors.Is(readErr, io.EOF) {
					dir.Close()
					return "", 0, readErr
				}
				for _, entry := range batch {
					child := entry.Name()
					if current.rel != "." {
						child = path.Join(current.rel, child)
					}
					if _, err := validate(child, false); err != nil {
						dir.Close()
						return "", 0, err
					}
					info, err := statEntryNoFollow(dir, entry.Name())
					if err != nil {
						dir.Close()
						return "", 0, err
					}
					entries++
					if entries > maxCopyEntries {
						dir.Close()
						return "", 0, ErrSize
					}
					if !info.IsDir() && !info.Mode().IsRegular() {
						dir.Close()
						return "", 0, ErrType
					}
					if err := add(child, info); err != nil {
						dir.Close()
						return "", 0, err
					}
					if info.IsDir() {
						queue = append(queue, pendingDirectory{rel: child})
					} else {
						file, err := s.openFileNoFollow(path.Join(name, child))
						if err != nil {
							dir.Close()
							return "", 0, err
						}
						opened, statErr := file.Stat()
						closeErr := file.Close()
						if statErr != nil || closeErr != nil || !sameTransferFile(opened, info) {
							dir.Close()
							return "", 0, errors.New("queued_source_changed_during_snapshot")
						}
					}
				}
				if errors.Is(readErr, io.EOF) {
					break
				}
			}
			after, err := dir.Stat()
			dir.Close()
			if err != nil || !sameDirectoryVersion(before, after) {
				return "", 0, errors.New("queued_source_directory_changed_during_snapshot")
			}
		}
	}
	sort.Strings(records)
	h := sha256.New()
	for _, record := range records {
		_, _ = io.WriteString(h, record+"\n")
	}
	return hex.EncodeToString(h.Sum(nil)), total, nil
}

func (s *Store) copyOutTree(ctx context.Context, src string, dest *os.Root, stage string) error {
	return s.copyOutTreeWithProgress(ctx, src, dest, stage, 0, nil)
}

func (s *Store) copyOutTreeWithProgress(ctx context.Context, src string, dest *os.Root, stage string, total int64, progress transferProgressFunc) error {
	output, err := dest.OpenRoot(stage)
	if err != nil {
		return err
	}
	defer output.Close()
	queue := []string{"."}
	entries := 0
	var bytesTotal int64
	var copied int64
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
					if progress != nil {
						err = progress("copying", copied, total)
					}
					if err == nil {
						report := func(n int64) error { return nil }
						if progress != nil {
							report = func(n int64) error { return progress("copying", copied+n, total) }
						}
						err = copyVerifiedWithProgress(ctx, destFile, source, stat.Size(), report)
					}
					if err == nil && progress != nil {
						copied += stat.Size()
						err = progress("verifying", copied, total)
					} else if err == nil {
						copied += stat.Size()
					}
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
		if !sameDirectoryVersion(before, after) {
			return errors.New("source_directory_changed_during_copy")
		}
	}
	if progress != nil {
		if err := progress("verifying", total, total); err != nil {
			return err
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
