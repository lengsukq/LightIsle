package files

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
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
	// Success is only reported after both affected directory entry sets have
	// been synced; otherwise a power loss could silently undo the move.
	return s.renameDurable(src, dst)
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
	if copyErr == nil {
		copyErr = s.syncFileContents(out)
	}
	closeErr := out.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	// The staging inode was fully flushed before publication, and the
	// destination name is only acknowledged once its directory entry is durable.
	return s.renameDurable(tmp, dst)
}

// Purge is intentionally restricted to an already trashed item. Live files
// cannot be irreversibly removed by this API. Trashed content is removed and
// made durable before its journal is forgotten: a crash in between leaves an
// orphan journal, which is recoverable, never untracked content.
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
	if err := s.syncTrashDirectory(); err != nil {
		return err
	}
	return s.removeTrashJournal(id)
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

// Conflict policies for optional same-name handling. The empty value keeps
// the historical behavior: an existing target fails with ErrExists (HTTP
// 409). There is deliberately no "replace" policy — LightIsle never
// overwrites an existing file through move/copy.
const (
	ConflictRefuse = ""
	ConflictSkip   = "skip"
	ConflictRename = "rename"
)

const maxRenameAttempts = 1000

// ValidateConflict normalizes the client-supplied conflict policy.
func ValidateConflict(value string) (string, error) {
	switch value {
	case ConflictRefuse, ConflictSkip, ConflictRename:
		return value, nil
	default:
		return "", ErrPath
	}
}

// renameCandidate generates the next "name (N).ext" candidate. Candidates go
// through the same validation as user-supplied paths, so an internal rename
// can never produce a reserved name.
func renameCandidate(pathValue string, attempt int) (string, error) {
	ext := filepath.Ext(pathValue)
	stem := strings.TrimSuffix(pathValue, ext)
	// A leading-dot name is all extension to filepath.Ext; generating from
	// an empty stem would produce an unrecognizable name.
	if stem == "" {
		return "", ErrPath
	}
	candidate := fmt.Sprintf("%s (%d)%s", stem, attempt, ext)
	if _, err := validate(candidate, false); err != nil {
		return "", err
	}
	return candidate, nil
}

func (m *Manager) MoveWithOptions(from, to, conflict string) (finalTo string, skipped bool, err error) {
	if conflict, err = ValidateConflict(conflict); err != nil {
		return "", false, err
	}
	m.opMu.Lock()
	defer m.opMu.Unlock()
	err = m.withRead(func(s *Store) error {
		finalTo, skipped, err = applyWithConflict(from, to, conflict, func(target string) error {
			return s.Move(from, target)
		})
		return err
	})
	return finalTo, skipped, err
}

func (m *Manager) CopyContextWithOptions(ctx context.Context, from, to, conflict string) (finalTo string, skipped bool, err error) {
	if conflict, err = ValidateConflict(conflict); err != nil {
		return "", false, err
	}
	m.opMu.Lock()
	defer m.opMu.Unlock()
	err = m.withRead(func(s *Store) error {
		finalTo, skipped, err = applyWithConflict(from, to, conflict, func(target string) error {
			return s.CopyContext(ctx, from, target)
		})
		return err
	})
	return finalTo, skipped, err
}

// applyWithConflict runs op against successive targets. The skip/rename
// decisions and the operation itself share the manager's opMu (the caller
// holds it), so a concurrent creator cannot slip between the existence check
// and the exclusive operation.
func applyWithConflict(from, to, conflict string, op func(string) error) (string, bool, error) {
	target := to
	for attempt := 1; attempt <= maxRenameAttempts; attempt++ {
		err := op(target)
		if err == nil {
			return target, false, nil
		}
		if !errors.Is(err, ErrExists) || conflict == ConflictRefuse {
			return "", false, err
		}
		if conflict == ConflictSkip {
			// Nothing was written for an existing target, so skipping is a
			// safe no-op; the exclusive primitive guarantees it.
			return target, true, nil
		}
		// Candidates always derive from the original target so repeated
		// conflicts produce "(2)", "(3)", … instead of nesting suffixes.
		next, candidateErr := renameCandidate(to, attempt+1)
		if candidateErr != nil {
			return "", false, candidateErr
		}
		target = next
	}
	return "", false, fmt.Errorf("%w: no free rename candidate for %s", ErrExists, from)
}

// NextRenameCandidate exposes the "name (N).ext" generator to callers that
// retry a conflicting operation themselves, such as upload staging.
func NextRenameCandidate(pathValue string, attempt int) (string, error) {
	return renameCandidate(pathValue, attempt)
}

// SweepTrashExpired permanently deletes trashed items whose deletion
// timestamp precedes cutoff, up to limit items per round. It relies on the
// journal-first trash design: a crashed round simply leaves the remaining
// items for the next sweep. A disabled cutoff (zero time) is rejected so
// callers cannot accidentally purge everything. Items whose purge fails are
// skipped but reported in failed, so the sweeper can keep its cleanup alert
// raised instead of silently clearing it on a healthy-looking round.
func (m *Manager) SweepTrashExpired(cutoff time.Time, limit int) (purged, failed []string, scanned int, err error) {
	if cutoff.IsZero() {
		return nil, nil, 0, errors.New("trash_sweep_disabled")
	}
	if limit < 1 {
		limit = 1
	}
	var candidates []string
	scanErr := m.withRead(func(s *Store) error {
		return s.forEachTrashEntry(func(entry TrashEntry) bool {
			scanned++
			if entry.DeletedAt.After(cutoff) {
				return true
			}
			candidates = append(candidates, entry.ID)
			// Enough candidates for this round; the next round continues.
			return len(candidates) < limit
		})
	})
	if scanErr != nil {
		return nil, nil, scanned, scanErr
	}
	purged = make([]string, 0, len(candidates))
	for _, id := range candidates {
		if purgeErr := m.Purge(id); purgeErr != nil {
			// One stuck item must not block the rest of the round; the
			// failure is reported through the sweeper's alert channel.
			failed = append(failed, id)
			continue
		}
		purged = append(purged, id)
	}
	return purged, failed, scanned, nil
}
