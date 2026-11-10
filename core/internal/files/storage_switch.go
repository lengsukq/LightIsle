package files

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"path"
	"slices"
	"sort"
	"strings"

	"golang.org/x/sys/unix"
)

func isIgnorableSwitchMetadata(name string) bool {
	return name == ".DS_Store" || strings.HasPrefix(name, "._")
}

// StorageSwitchFile identifies a regular file on its original volume and
// carries the independently verified content digest.
type StorageSwitchFile struct {
	Path     string
	Size     int64
	Identity string
	Digest   string
}

func (m *Manager) StorageSwitchTreeIgnoring(ctx context.Context, prefix string, hash bool, ignored map[string]string) (tree StorageSwitchTree, err error) {
	err = m.withRead(func(s *Store) (e error) { tree, e = s.storageSwitchTreeIgnoring(ctx, prefix, hash, ignored); return })
	return
}

// Verify an expected controlled symlink with an already-open directory fd.
// A replaced link or an ordinary file at that path is a hard conflict.
func verifyExcludedSwitchLink(dir *os.File, leaf, expected string) error {
	if expected == "" {
		return ErrType
	}
	var before, after unix.Stat_t
	if err := unix.Fstatat(int(dir.Fd()), leaf, &before, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	if before.Mode&unix.S_IFMT != unix.S_IFLNK {
		return ErrType
	}
	buf := make([]byte, 1024)
	n, err := unix.Readlinkat(int(dir.Fd()), leaf, buf)
	if err != nil {
		return err
	}
	if err := unix.Fstatat(int(dir.Fd()), leaf, &after, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	if before.Dev != after.Dev || before.Ino != after.Ino ||
		before.Mode&unix.S_IFMT != after.Mode&unix.S_IFMT ||
		n <= 0 || n >= len(buf) || string(buf[:n]) != expected {
		return ErrExists
	}
	return nil
}

type StorageSwitchTree struct {
	Directories         []string
	DirectoryIdentities map[string]string
	Files               []StorageSwitchFile
	Bytes               int64
}

func (tree StorageSwitchTree) SameContent(other StorageSwitchTree) bool {
	if tree.Bytes != other.Bytes || len(tree.Files) != len(other.Files) || len(tree.Directories) != len(other.Directories) {
		return false
	}
	for i, name := range tree.Directories {
		if name != other.Directories[i] {
			return false
		}
	}
	for i, file := range tree.Files {
		match := other.Files[i]
		if file.Path != match.Path || file.Size != match.Size || file.Digest != match.Digest {
			return false
		}
	}
	return true
}

// ignored is a per-task snapshot of registered, controlled folder-album
// symlinks. Never skip an arbitrary link or a link whose target changed.
func (s *Store) storageSwitchTree(ctx context.Context, prefix string, hash bool) (StorageSwitchTree, error) {
	return s.storageSwitchTreeIgnoring(ctx, prefix, hash, nil)
}

func (s *Store) storageSwitchTreeIgnoring(ctx context.Context, prefix string, hash bool, ignored map[string]string) (StorageSwitchTree, error) {
	tree := StorageSwitchTree{DirectoryIdentities: make(map[string]string)}
	pending := []string{"."}
	for len(pending) != 0 {
		if err := ctx.Err(); err != nil {
			return tree, err
		}
		relative := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		tree.Directories = append(tree.Directories, relative)
		dir, err := s.openDirNoFollow(path.Join(prefix, relative))
		if err != nil {
			return tree, err
		}
		err = func() error {
			defer dir.Close()
			start, err := dir.Stat()
			if err != nil {
				return err
			}
			identity := trashObjectIdentity(start)
			if identity == "" {
				return ErrType
			}
			tree.DirectoryIdentities[relative] = identity
			for {
				if err := ctx.Err(); err != nil {
					return err
				}
				batch, readErr := dir.ReadDir(128)
				if readErr != nil && !errors.Is(readErr, io.EOF) {
					return readErr
				}
				for _, entry := range batch {
					if isIgnorableSwitchMetadata(entry.Name()) {
						continue
					}
					child := path.Join(relative, entry.Name())
					if _, err := validate(child, false); err != nil {
						return err
					}
					if target, ok := ignored[path.Join(prefix, child)]; ok {
						if err := verifyExcludedSwitchLink(dir, entry.Name(), target); err != nil {
							return err
						}
						continue
					}
					info, err := statEntryNoFollow(dir, entry.Name())
					if err != nil {
						return err
					}
					if len(tree.Files)+len(tree.Directories)+len(pending) >= maxStorageSwitchEntries {
						return ErrSize
					}
					if info.IsDir() {
						pending = append(pending, child)
						continue
					}
					if !info.Mode().IsRegular() || !MediaFileHasSingleLink(info) {
						return ErrType
					}
					if info.Size() < 0 || info.Size() > maxStorageSwitchBytes-tree.Bytes {
						return ErrSize
					}
					item := StorageSwitchFile{Path: child, Size: info.Size(), Identity: MediaFileIdentity(info)}
					if item.Identity == "" {
						return ErrType
					}
					if hash {
						file, err := s.openFileNoFollow(path.Join(prefix, child))
						if err != nil {
							return err
						}
						opened, err := file.Stat()
						if err != nil || !opened.Mode().IsRegular() || MediaFileIdentity(opened) != item.Identity ||
							opened.Size() != item.Size || !opened.ModTime().Equal(info.ModTime()) {
							file.Close()
							return errors.Join(ErrExists, err)
						}
						sum, err := hashStableFile(ctx, file, opened)
						file.Close()
						if err != nil {
							return err
						}
						item.Digest = hex.EncodeToString(sum[:])
					}
					tree.Files = append(tree.Files, item)
					tree.Bytes += info.Size()
				}
				if errors.Is(readErr, io.EOF) {
					break
				}
			}
			end, err := dir.Stat()
			if err != nil {
				return err
			}
			if !sameDirectoryVersion(start, end) {
				return ErrExists
			}
			return nil
		}()
		if err != nil {
			return tree, err
		}
	}
	sort.Strings(tree.Directories)
	sort.Slice(tree.Files, func(i, j int) bool { return tree.Files[i].Path < tree.Files[j].Path })
	return tree, nil
}

func (m *Manager) StorageSwitchTree(ctx context.Context, prefix string, hash bool) (tree StorageSwitchTree, err error) {
	err = m.withRead(func(s *Store) (e error) { tree, e = s.storageSwitchTree(ctx, prefix, hash); return })
	return
}

func openPrivateSwitchStage(s *Store, taskID string, create bool) (*os.Root, error) {
	if !trashIDRule.MatchString(taskID) {
		return nil, ErrPath
	}
	name := ".lightisle-switch-" + taskID
	if create {
		if err := s.root.Mkdir(name, 0700); err != nil {
			return nil, err
		}
	}
	info, err := s.root.Lstat(name)
	if err != nil || !info.IsDir() {
		return nil, errors.Join(ErrPath, err)
	}
	stage, err := s.root.OpenRoot(name)
	if err != nil {
		return nil, err
	}
	actual, err := stage.Stat(".")
	if err != nil || !os.SameFile(info, actual) {
		stage.Close()
		return nil, errors.Join(ErrExists, err)
	}
	return stage, nil
}

func (m *Manager) StageStorageSwitch(ctx context.Context, target *Manager, taskID string, paths []string, total int64, created func(string) error, report func(int64), ignoredLinks ...map[string]string) error {
	var excluded map[string]string
	if len(ignoredLinks) > 0 {
		excluded = ignoredLinks[0]
	}
	if total < 0 || total > maxStorageSwitchBytes {
		return ErrSize
	}
	return m.withRead(func(src *Store) error {
		return target.withRead(func(dst *Store) error {
			stage, err := openPrivateSwitchStage(dst, taskID, true)
			if err != nil {
				return err
			}
			defer stage.Close()
			info, err := stage.Stat(".")
			if err != nil {
				return err
			}
			identity := trashObjectIdentity(info)
			if identity == "" {
				return ErrType
			}
			if err := created(identity); err != nil {
				return err
			}
			var processed int64
			for _, prefix := range paths {
				category := path.Base(prefix)
				if err := stage.Mkdir(category, 0700); err != nil {
					return err
				}
				var count int64
				err := src.copyOutTreeWithProgressLimits(ctx, prefix, stage, category, 0, func(phase string, copied, _ int64) error {
					if processed+copied > total {
						return ErrSize
					}
					if copied > count {
						count = copied
						report(processed + copied)
					}
					return ctx.Err()
				}, maxStorageSwitchEntries, maxStorageSwitchBytes, excluded)
				if err != nil {
					return err
				}
				processed += count
			}
			return dst.syncDirectory(".")
		})
	})
}

func (m *Manager) StagedStorageSwitchTree(ctx context.Context, taskID, category string) (tree StorageSwitchTree, err error) {
	err = m.withRead(func(s *Store) error {
		stage, err := openPrivateSwitchStage(s, taskID, false)
		if err != nil {
			return err
		}
		defer stage.Close()
		tree, err = (&Store{root: stage}).storageSwitchTree(ctx, category, true)
		return err
	})
	return
}

func (m *Manager) PublishStorageSwitch(taskID, relative string) error {
	return m.withRead(func(s *Store) error {
		if _, err := validate(relative, false); err != nil {
			return err
		}
		stage, err := openPrivateSwitchStage(s, taskID, false)
		if err != nil {
			return err
		}
		defer stage.Close()
		source, err := stage.Open(".")
		if err != nil {
			return err
		}
		defer source.Close()
		destination, err := s.openDirNoFollow(path.Dir(relative))
		if err != nil {
			return err
		}
		defer destination.Close()
		category := path.Base(relative)
		_ = unix.Unlinkat(int(destination.Fd()), category, unix.AT_REMOVEDIR)
		if err := renameAtNoReplace(int(source.Fd()), category, int(destination.Fd()), category); err != nil {
			return err
		}
		return errors.Join(s.syncDirContents(destination), s.syncDirContents(source))
	})
}

// SyncStorageSwitchPublication completes the directory sync after an
// interrupted rename. The caller has already verified the published tree.
func (m *Manager) SyncStorageSwitchPublication(taskID, relative string) error {
	return m.withRead(func(s *Store) error {
		stage, err := openPrivateSwitchStage(s, taskID, false)
		if err != nil {
			return err
		}
		defer stage.Close()
		source, err := stage.Open(".")
		if err != nil {
			return err
		}
		defer source.Close()
		destination, err := s.openDirNoFollow(path.Dir(relative))
		if err != nil {
			return err
		}
		defer destination.Close()
		return errors.Join(s.syncDirContents(destination), s.syncDirContents(source))
	})
}

// DiscardStorageSwitch removes only the private stage with the task's exact
// name. The server calls it only before publication and while the disk lease
// is still valid. Published data is left in place for manual reconciliation.
func (m *Manager) DiscardStorageSwitch(taskID, identity string) error {
	if !trashIDRule.MatchString(taskID) {
		return ErrPath
	}
	return m.withRead(func(s *Store) error {
		name := ".lightisle-switch-" + taskID
		info, err := s.root.Lstat(name)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil || !info.IsDir() || identity == "" || trashObjectIdentity(info) != identity {
			return errors.Join(ErrPath, err)
		}
		stage, err := openPrivateSwitchStage(s, taskID, false)
		if err != nil {
			return err
		}
		defer stage.Close()
		opened, err := stage.Stat(".")
		if err != nil || !os.SameFile(info, opened) {
			return errors.Join(ErrExists, err)
		}
		entries, err := stage.Open(".")
		if err != nil {
			return err
		}
		defer entries.Close()
		for {
			names, readErr := entries.Readdirnames(128)
			if readErr != nil && !errors.Is(readErr, io.EOF) {
				return readErr
			}
			for _, child := range names {
				if err := stage.RemoveAll(child); err != nil {
					return err
				}
			}
			if errors.Is(readErr, io.EOF) {
				break
			}
		}
		current, err := s.root.Lstat(name)
		if err != nil || !os.SameFile(info, current) {
			return errors.Join(ErrExists, err)
		}
		if err := s.root.Remove(name); err != nil {
			return err
		}
		return s.syncDirectory(".")
	})
}

// TrashStorageSwitch verifies the full tree again after the native rename.
// If a local writer raced the move, restore by exact receipt without replacing
// anything at the original path. Both copies survive any uncertain result.
func (m *Manager) TrashStorageSwitch(ctx context.Context, prefix string, expected StorageSwitchTree, trashID string) error {
	if !trashIDRule.MatchString(trashID) {
		return ErrPath
	}
	return m.withRead(func(s *Store) error {
		unlock, err := s.lockTrash()
		if err != nil {
			return err
		}
		defer unlock()
		if entry, err := s.TrashInfo(trashID); err == nil {
			if entry.OriginalPath != prefix {
				return ErrTrashChanged
			}
			return s.verifyStorageSwitchTrash(ctx, entry, expected)
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		info, err := s.Stat(prefix)
		if err != nil {
			return err
		}
		current, err := s.storageSwitchTree(ctx, prefix, true)
		if err != nil || !expected.SameObjects(current) {
			return errors.Join(ErrExists, err)
		}
		if err := s.moveToTrashWithID(prefix, info, trashID); err != nil {
			return err
		}
		entry, err := s.TrashInfo(trashID)
		if err == nil {
			err = s.verifyStorageSwitchTrash(ctx, entry, expected)
		}
		if err != nil {
			return errors.Join(fmt.Errorf("storage_switch_source_changed: %w", err), s.restoreLocked(trashID))
		}
		return nil
	})
}

func (s *Store) verifyStorageSwitchTrash(ctx context.Context, entry TrashEntry, expected StorageSwitchTree) error {
	if entry.ObjectIdentity == "" || entry.ObjectIdentity != expected.DirectoryIdentities["."] {
		return ErrTrashChanged
	}
	if err := s.verifyTrashIdentity(entry); err != nil {
		return err
	}
	trashDir, err := s.openTrashDirNoFollow()
	if err != nil {
		return err
	}
	defer trashDir.Close()
	fd, err := unix.Openat(int(trashDir.Fd()), entry.ID, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	opened := os.NewFile(uintptr(fd), entry.ID)
	defer opened.Close()
	moved, err := opened.Stat()
	if err != nil || trashObjectIdentity(moved) != entry.ObjectIdentity {
		return errors.Join(ErrTrashChanged, err)
	}
	root, err := s.root.OpenRoot(path.Join(Trash, entry.ID))
	if err != nil {
		return err
	}
	defer root.Close()
	actual, err := root.Stat(".")
	if err != nil || !os.SameFile(moved, actual) {
		return errors.Join(ErrTrashChanged, err)
	}
	verified, err := (&Store{root: root}).storageSwitchTree(ctx, ".", true)
	if err != nil || !expected.SameObjects(verified) {
		return errors.Join(ErrTrashChanged, err)
	}
	return nil
}

func (tree StorageSwitchTree) SameObjects(other StorageSwitchTree) bool {
	return tree.SameContent(other) && slices.Equal(tree.Files, other.Files) &&
		maps.Equal(tree.DirectoryIdentities, other.DirectoryIdentities)
}
