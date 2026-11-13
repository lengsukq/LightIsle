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
	return s.copyContext(ctx, from, to, nil)
}

func (s *Store) copyContext(ctx context.Context, from, to string, capturedIdentity *string) error {
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
		if capturedIdentity != nil {
			return ErrType
		}
		return s.copyDirectory(ctx, src, dst)
	}
	if !info.Mode().IsRegular() {
		return ErrType
	}
	return s.copyRegular(ctx, src, dst, capturedIdentity)
}
func (s *Store) copyRegular(ctx context.Context, src, dst string, capturedIdentity *string) error {
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
	defer s.root.Remove(tmp)
	var out *os.File
	var copyErr error
	if cloned, ok := s.cloneRegularToStage(src, tmp, info); ok {
		out = cloned
	} else {
		out, err = s.root.OpenFile(tmp, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return err
		}
		copyErr = copyVerified(ctx, out, f, info.Size())
	}
	if copyErr == nil {
		copyErr = s.syncFileContents(out)
	}
	var stagedIdentity string
	if copyErr == nil && capturedIdentity != nil {
		if stagedInfo, statErr := out.Stat(); statErr == nil && stagedInfo.Size() == info.Size() && MediaFileHasSingleLink(stagedInfo) {
			stagedIdentity = MediaFileIdentity(stagedInfo)
		}
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
	if err := s.renameDurable(tmp, dst); err != nil {
		return err
	}
	if capturedIdentity != nil && stagedIdentity != "" {
		published, err := s.Stat(dst)
		if err != nil || published.Size() != info.Size() || !MediaFileHasSingleLink(published) || MediaFileIdentity(published) != stagedIdentity {
			return fmt.Errorf("%w: published copy identity changed", ErrPublishedSync)
		}
		*capturedIdentity = stagedIdentity
	}
	return nil
}

// Purge is intentionally restricted to an already trashed item. Live files
// cannot be irreversibly removed by this API. Trashed content is removed and
// made durable before its journal is forgotten: a crash in between leaves an
// orphan journal, which is recoverable, never untracked content.
func (s *Store) Purge(id string) error {
	unlock, err := s.lockTrash()
	if err != nil {
		return err
	}
	defer unlock()
	if !trashIDRule.MatchString(id) {
		return ErrPath
	}
	entry, err := s.readTrashJournal(id)
	if err != nil {
		return err
	}
	if err := s.verifyTrashIdentity(entry); err != nil {
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
	return s.SearchKind(base, term, "", limit)
}

func (s *Store) SearchKind(base, term, kind string, limit int) ([]Entry, bool, error) {
	base, err := validate(base, true)
	if err != nil {
		return nil, false, err
	}
	if !ValidSearchKind(kind) || limit < 1 || limit > 200 {
		return nil, false, ErrPath
	}
	tokens, err := ParseSearchTokens(term)
	if err != nil {
		return nil, false, err
	}
	candidateCap := limit * 4
	if candidateCap < 400 {
		candidateCap = 400
	}
	queue := []string{base}
	result := make([]Entry, 0, limit)
	visited := 0
	for len(queue) > 0 && visited < 30000 && len(result) < candidateCap {
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
				if MatchesSearchTokens(entry, tokens) && MatchesSearchKind(entry, kind) {
					result = append(result, entry)
					if len(result) >= candidateCap {
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
			if next == "" || visited >= 30000 || len(result) >= candidateCap {
				break
			}
			cursor = next
		}
	}
	truncated := len(queue) > 0 || visited >= 30000 || len(result) > limit
	RankSearchEntries(result, term)
	if len(result) > limit {
		result = result[:limit]
	}
	return result, truncated, nil
}

func ValidSearchKind(kind string) bool {
	switch kind {
	case "", "all", "folder", "image", "video", "audio", "document", "archive":
		return true
	default:
		return false
	}
}

func MatchesSearchKind(entry Entry, kind string) bool {
	if kind == "" || kind == "all" {
		return true
	}
	if kind == "folder" {
		return entry.Type == "folder"
	}
	if entry.Type == "folder" {
		return false
	}
	ext := strings.ToLower(filepath.Ext(entry.Name))
	switch kind {
	case "image":
		switch ext {
		case ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".bmp", ".svg", ".tif", ".tiff", ".raw", ".dng", ".cr2", ".nef", ".arw":
			return true
		}
	case "video":
		switch ext {
		case ".mp4", ".mov", ".m4v", ".mkv", ".avi", ".webm", ".ts", ".flv", ".wmv":
			return true
		}
	case "audio":
		switch ext {
		case ".mp3", ".m4a", ".flac", ".wav", ".aac", ".ogg", ".opus", ".ape", ".wma", ".aiff", ".aif", ".alac", ".m4b":
			return true
		}
	case "document":
		switch ext {
		case ".pdf", ".txt", ".md", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".csv", ".json", ".pages", ".numbers", ".key", ".rtf", ".epub", ".odt", ".ods", ".odp":
			return true
		}
	case "archive":
		switch ext {
		case ".zip", ".tar", ".gz", ".tgz", ".7z", ".rar", ".bz2", ".xz", ".dmg", ".iso":
			return true
		}
	}
	return false
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
	finalTo, skipped, _, err = m.copyContextWithOptions(ctx, from, to, conflict, false)
	return
}

// CopyContextWithOptionsAndIdentity captures the new file identity before the
// temporary copy is published and checks it against the destination afterward.
func (m *Manager) CopyContextWithOptionsAndIdentity(ctx context.Context, from, to, conflict string) (finalTo string, skipped bool, identity string, err error) {
	return m.copyContextWithOptions(ctx, from, to, conflict, true)
}

func (m *Manager) copyContextWithOptions(ctx context.Context, from, to, conflict string, capture bool) (finalTo string, skipped bool, identity string, err error) {
	if conflict, err = ValidateConflict(conflict); err != nil {
		return "", false, "", err
	}
	m.opMu.Lock()
	defer m.opMu.Unlock()
	err = m.withRead(func(s *Store) error {
		finalTo, skipped, err = applyWithConflict(from, to, conflict, func(target string) error {
			if capture {
				identity = ""
				return s.copyContext(ctx, from, target, &identity)
			}
			return s.CopyContext(ctx, from, target)
		})
		return err
	})
	return finalTo, skipped, identity, err
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
