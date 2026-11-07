//go:build darwin

package files

import (
	"errors"
	"fmt"
	"os"
	"path"
	"strings"

	"golang.org/x/sys/unix"
)

// TrashFileInspection describes a regular file opened without following any
// path component. Identity has the same format as the quota ledger.
type TrashFileInspection struct {
	Identity string
	Size     int64
}

// TrashPurgePrepare runs while the trash item is locked against other
// LightIsle restore, trash and purge operations. inspect accepts paths relative
// to the trashed item; "." identifies a trashed regular file itself.
// The returned function commits the matching accounting only AFTER durable
// removal. It must recheck the physical root before releasing any charge.
type TrashPurgePrepare func(entry TrashEntry, inspect func(string) (TrashFileInspection, error)) (func() error, error)

// PurgeWithAccounting keeps the trash lock through inspection, durable
// deletion and accounting. Failure after deletion retains the trash journal
// and does not claim success; callers must preserve uncertain accounting.
func (s *Store) PurgeWithAccounting(id string, prepare TrashPurgePrepare) error {
	if prepare == nil || !trashIDRule.MatchString(id) {
		return ErrPath
	}
	unlock, err := s.lockTrash()
	if err != nil {
		return err
	}
	defer unlock()
	entry, err := s.TrashInfo(id)
	if err != nil {
		return err
	}
	// Old journals cannot prove which filesystem object was trashed.
	if entry.ObjectIdentity == "" {
		return ErrTrashIdentityUnknown
	}
	trashDir, err := s.openTrashDirNoFollow()
	if err != nil {
		return err
	}
	defer trashDir.Close()
	fd, err := unix.Openat(int(trashDir.Fd()), id, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC|unix.O_NONBLOCK, 0)
	if err != nil {
		return err
	}
	item := os.NewFile(uintptr(fd), id)
	defer item.Close()
	info, err := item.Stat()
	if err != nil {
		return err
	}
	if trashObjectIdentity(info) != entry.ObjectIdentity {
		return ErrTrashChanged
	}
	inspected := make(map[string]TrashFileInspection)
	inspect := func(relative string) (TrashFileInspection, error) {
		result, err := inspectAccountedTrashFile(item, info, relative)
		if err == nil {
			if old, exists := inspected[relative]; exists && old != result {
				return TrashFileInspection{}, ErrTrashChanged
			}
			inspected[relative] = result
		}
		return result, err
	}
	commit, err := prepare(entry, inspect)
	if err != nil {
		return err
	}
	if commit == nil {
		return ErrPath
	}
	for relative, previous := range inspected {
		current, err := inspectAccountedTrashFile(item, info, relative)
		if err != nil || current != previous {
			return ErrTrashChanged
		}
	}
	if err := verifyAllTrashFilesInspected(item, info, inspected); err != nil {
		return err
	}
	// Confirm the name still addresses the object we inspected. The private
	// directory is pinned, and other app trash transitions hold the same lock.
	current, err := statEntryNoFollow(trashDir, id)
	if err != nil {
		return err
	}
	if trashObjectIdentity(current) != entry.ObjectIdentity {
		return ErrTrashChanged
	}
	if err := s.root.RemoveAll(path.Join(Trash, id)); err != nil {
		return err
	}
	if err := s.syncDirContents(trashDir); err != nil {
		return fmt.Errorf("%w: trash removal could not be confirmed: %v", ErrTrashAccountingUncertain, err)
	}
	if err := commit(); err != nil {
		return fmt.Errorf("%w: %v", ErrTrashAccountingUncertain, err)
	}
	if err := s.removeTrashJournal(id); err != nil {
		return fmt.Errorf("%w: trash journal cleanup failed: %v", ErrTrashAccountingUncertain, err)
	}
	return nil
}

func inspectAccountedTrashFile(item *os.File, itemInfo os.FileInfo, relative string) (TrashFileInspection, error) {
	var file *os.File
	if relative == "." {
		if !itemInfo.Mode().IsRegular() {
			return TrashFileInspection{}, ErrType
		}
		file = item
	} else {
		if _, err := validate(relative, false); err != nil || !itemInfo.IsDir() {
			return TrashFileInspection{}, ErrPath
		}
		components := strings.Split(relative, "/")
		parent := item
		for index, component := range components {
			flags := unix.O_RDONLY | unix.O_NOFOLLOW | unix.O_CLOEXEC | unix.O_NONBLOCK
			if index < len(components)-1 {
				flags |= unix.O_DIRECTORY
			}
			fd, err := unix.Openat(int(parent.Fd()), component, flags, 0)
			if parent != item {
				_ = parent.Close()
			}
			if err != nil {
				if errors.Is(err, unix.ELOOP) || errors.Is(err, unix.ENOTDIR) {
					return TrashFileInspection{}, ErrType
				}
				return TrashFileInspection{}, err
			}
			parent = os.NewFile(uintptr(fd), component)
		}
		file = parent
		defer file.Close()
	}
	info, err := file.Stat()
	if err != nil {
		return TrashFileInspection{}, err
	}
	identity := MediaFileIdentity(info)
	if identity == "" || !MediaFileHasSingleLink(info) || info.Size() < 0 {
		return TrashFileInspection{}, ErrTrashIdentityUnknown
	}
	return TrashFileInspection{Identity: identity, Size: info.Size()}, nil
}

func verifyAllTrashFilesInspected(item *os.File, itemInfo os.FileInfo, inspected map[string]TrashFileInspection) error {
	if !itemInfo.IsDir() {
		if _, ok := inspected["."]; !ok {
			return ErrTrashIdentityUnknown
		}
		return nil
	}
	const maxVisited = 10000
	const maxDepth = 64
	visited := 0
	var walk func(dir *os.File, prefix string, depth int) error
	walk = func(dir *os.File, prefix string, depth int) error {
		if depth > maxDepth {
			return ErrTrashIdentityUnknown
		}
		if _, err := dir.Seek(0, 0); err != nil {
			return err
		}
		names, err := dir.Readdirnames(-1)
		if err != nil {
			return err
		}
		for _, name := range names {
			visited++
			if visited > maxVisited {
				return ErrTrashIdentityUnknown
			}
			childInfo, err := statEntryNoFollow(dir, name)
			if err != nil {
				return ErrTrashChanged
			}
			rel := name
			if prefix != "" {
				rel = prefix + "/" + name
			}
			if childInfo.Mode()&os.ModeSymlink != 0 {
				return ErrType
			}
			if childInfo.IsDir() {
				fd, err := unix.Openat(int(dir.Fd()), name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NONBLOCK, 0)
				if err != nil {
					return ErrTrashChanged
				}
				childDir := os.NewFile(uintptr(fd), rel)
				walkErr := walk(childDir, rel, depth+1)
				_ = childDir.Close()
				if walkErr != nil {
					return walkErr
				}
				continue
			}
			if !childInfo.Mode().IsRegular() {
				return ErrType
			}
			expected, ok := inspected[rel]
			if !ok {
				return ErrTrashIdentityUnknown
			}
			if !MediaFileHasSingleLink(childInfo) || MediaFileIdentity(childInfo) != expected.Identity || childInfo.Size() != expected.Size {
				return ErrTrashChanged
			}
		}
		return nil
	}
	return walk(item, "", 0)
}
