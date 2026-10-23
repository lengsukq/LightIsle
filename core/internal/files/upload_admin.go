package files

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"sort"
	"strings"
)

const maxExpiredUploadCleanup = 100

const (
	maxUploadDirectoryEntries = 8192
	maxUploadInventoryRecords = 4096
	maxUploadJournalBytes     = 4096
	maxUploadInventoryBytes   = 16 << 20
)

var ErrUploadInventoryLimit = errors.New("upload_inventory_limit")

// UploadRecord is an administrative view of a resumable upload. Size and
// offset come from the journal when it exists; a part-only orphan reports its
// staged byte count as size and has no trusted owner or destination.
type UploadRecord struct {
	State       UploadState
	PartPresent bool
	PartSize    int64
	Orphan      bool
	Corrupt     bool
}

func uploadIDFromName(name, suffix string) (string, bool) {
	if !strings.HasSuffix(name, suffix) {
		return "", false
	}
	id := strings.TrimSuffix(name, suffix)
	return id, uploadIDPattern.MatchString(id)
}

func (s *Store) uploadRecords() ([]UploadRecord, error) {
	root, _, err := s.openExistingUploadsRoot()
	if err != nil {
		return nil, err
	}
	if root == nil {
		return []UploadRecord{}, nil
	}
	dir, err := root.Open(".")
	if err != nil {
		return nil, err
	}
	entries := make([]fs.DirEntry, 0, 1024)
	for {
		batch, readErr := dir.ReadDir(1024)
		entries = append(entries, batch...)
		if len(entries) >= maxUploadDirectoryEntries {
			_ = dir.Close()
			return nil, ErrUploadInventoryLimit
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			_ = dir.Close()
			return nil, readErr
		}
		if len(batch) == 0 {
			break
		}
	}
	closeErr := dir.Close()
	if closeErr != nil {
		return nil, closeErr
	}

	journalIDs := make(map[string]struct{})
	partIDs := make(map[string]struct{})
	for _, entry := range entries {
		if id, ok := uploadIDFromName(entry.Name(), ".json"); ok {
			journalIDs[id] = struct{}{}
		}
		if id, ok := uploadIDFromName(entry.Name(), ".part"); ok {
			partIDs[id] = struct{}{}
		}
	}

	ids := make(map[string]struct{}, len(journalIDs)+len(partIDs))
	for id := range journalIDs {
		ids[id] = struct{}{}
	}
	for id := range partIDs {
		ids[id] = struct{}{}
	}
	if len(ids) > maxUploadInventoryRecords {
		return nil, ErrUploadInventoryLimit
	}
	ordered := make([]string, 0, len(ids))
	for id := range ids {
		ordered = append(ordered, id)
	}
	sort.Strings(ordered)

	records := make([]UploadRecord, 0, len(ordered))
	journalBytes := int64(0)
	journalCount := 0
	for _, id := range ordered {
		_, hasJournal := journalIDs[id]
		_, hasPart := partIDs[id]
		record := UploadRecord{State: UploadState{ID: id}}
		if hasJournal {
			journalInfo, statErr := root.Lstat(id + ".json")
			if statErr != nil {
				return nil, statErr
			}
			journalCount++
			journalBytes += journalInfo.Size()
			if journalCount > maxUploadInventoryRecords || journalBytes > maxUploadInventoryBytes {
				return nil, ErrUploadInventoryLimit
			}
			meta, metaErr := readUploadJournalFrom(root, id)
			if metaErr != nil {
				if !errors.Is(metaErr, ErrPath) && !errors.Is(metaErr, ErrType) {
					return nil, metaErr
				}
				record.Corrupt = true
				record.Orphan = true
				if info, statErr := root.Lstat(id + ".json"); statErr == nil {
					record.State.Activity = info.ModTime().Unix()
				}
			} else {
				record.State = meta
				if meta.Size < 0 || meta.Size > maxResumableSize || meta.Offset < 0 || meta.Offset > meta.Size {
					record.Corrupt = true
				}
			}
		}

		partPath := id + ".part"
		partInfo, partErr := root.Lstat(partPath)
		if partErr == nil {
			if !partInfo.Mode().IsRegular() {
				record.Corrupt = true
				record.Orphan = true
			} else {
				record.PartPresent = true
				record.PartSize = partInfo.Size()
				legacyAlias := false
				if hasJournal {
					if destInfo, destErr := s.root.Lstat(record.State.Path); destErr == nil && destInfo.Mode().IsRegular() && os.SameFile(partInfo, destInfo) {
						legacyAlias = true
						record.State.Published = true
					}
				}
				if err := validatePrivateUploadPart(partInfo); err != nil && !legacyAlias {
					record.Corrupt = true
					record.Orphan = true
				}
				if !hasJournal {
					record.State.Size = partInfo.Size()
					record.State.Activity = partInfo.ModTime().Unix()
					record.Orphan = true
				}
				if hasJournal && record.State.Version < 2 && !record.State.Published && !record.Corrupt {
					record.State.Offset = partInfo.Size()
				}
				if hasJournal && !record.State.Published && partInfo.Size() < record.State.Offset {
					record.Corrupt = true
					record.Orphan = true
				}
			}
		} else if errors.Is(partErr, fs.ErrNotExist) {
			if hasJournal && !record.State.Published {
				if record.State.sourceIdentity == nil {
					record.Orphan = true
				} else if destInfo, destErr := s.root.Lstat(record.State.Path); destErr == nil && destInfo.Mode().IsRegular() {
					if sameUploadInode(record.State.sourceIdentity, destInfo) {
						record.State.Published = true
					} else {
						record.Corrupt = true
						record.Orphan = true
					}
				} else {
					record.Corrupt = true
					record.Orphan = true
				}
			} else if hasJournal && record.State.Published {
				if record.State.sourceIdentity == nil {
					// Legacy published journals without a staged alias cannot prove
					// that a surviving destination still belongs to this upload.
					record.Corrupt = true
					record.Orphan = true
				} else if destInfo, destErr := s.root.Lstat(record.State.Path); destErr == nil && destInfo.Mode().IsRegular() {
					if !sameUploadInode(record.State.sourceIdentity, destInfo) {
						record.Corrupt = true
						record.Orphan = true
					}
				} else {
					record.Corrupt = true
					record.Orphan = true
				}
			}
		} else {
			return nil, partErr
		}
		if !hasJournal && hasPart && record.State.Activity <= 0 {
			// A malformed or non-regular part must not become eligible for
			// expiry cleanup merely because its timestamp is unavailable.
			record.Corrupt = true
		}
		records = append(records, record)
	}
	return records, nil
}

// ListUploads returns stable ID-ordered upload records after the supplied
// cursor. It never repairs or truncates upload data while listing it.
func (s *Store) ListUploads(after string, limit int) ([]UploadRecord, string, error) {
	if !s.uploadMu.TryLock() {
		return nil, "", ErrUploadBusy
	}
	defer s.uploadMu.Unlock()
	return s.listUploads(after, limit)
}

func (s *Store) listUploads(after string, limit int) ([]UploadRecord, string, error) {
	if limit < 1 || limit > 100 || (after != "" && !uploadIDPattern.MatchString(after)) {
		return nil, "", ErrPath
	}
	records, err := s.uploadRecords()
	if err != nil {
		return nil, "", err
	}
	start := 0
	for start < len(records) && records[start].State.ID <= after {
		start++
	}
	pageEnd := start + limit
	if pageEnd >= len(records) {
		return records[start:], "", nil
	}
	return records[start:pageEnd], records[pageEnd-1].State.ID, nil
}

// CancelUpload removes only upload staging metadata and bytes. A published
// destination has already been moved out of the pinned staging directory.
// The try-lock returns a conflict instead of racing a chunk write or commit.
func (s *Store) CancelUpload(id string) error {
	if !s.uploadMu.TryLock() {
		return ErrUploadBusy
	}
	defer s.uploadMu.Unlock()
	return s.removeUploadFiles(id)
}

// CleanupExpiredUploads removes up to 100 stale, unpublished, non-corrupt
// sessions. This API is called only by an explicit administrator request.
// Published recovery journals and malformed state are reported as skipped.
func (s *Store) CleanupExpiredUploads(beforeActivity int64) (removed []string, skipped int, hasMore bool, err error) {
	if !s.uploadMu.TryLock() {
		return nil, 0, false, ErrUploadBusy
	}
	defer s.uploadMu.Unlock()
	return s.cleanupExpiredUploads(beforeActivity)
}

func (s *Store) cleanupExpiredUploads(beforeActivity int64) (removed []string, skipped int, hasMore bool, err error) {
	records, err := s.uploadRecords()
	if err != nil {
		return nil, 0, false, err
	}
	candidates := make([]UploadRecord, 0)
	for _, record := range records {
		activity := record.State.Activity
		if activity <= 0 || activity >= beforeActivity {
			continue
		}
		if record.State.Published || record.Corrupt {
			skipped++
			continue
		}
		candidates = append(candidates, record)
	}
	if len(candidates) > maxExpiredUploadCleanup {
		hasMore = true
		candidates = candidates[:maxExpiredUploadCleanup]
	}
	for _, record := range candidates {
		if err := s.removeUploadFiles(record.State.ID); err != nil {
			return removed, skipped, hasMore, err
		}
		removed = append(removed, record.State.ID)
	}
	return removed, skipped, hasMore, nil
}

func (s *Store) removeUploadFiles(id string) error {
	if !uploadIDPattern.MatchString(id) {
		return ErrPath
	}
	root, _, err := s.openExistingUploadsRoot()
	if err != nil {
		return err
	}
	if root == nil {
		return fs.ErrNotExist
	}
	partPath := id + ".part"
	metaPath := id + ".json"
	partInfo, partErr := root.Lstat(partPath)
	if partErr != nil && !errors.Is(partErr, fs.ErrNotExist) {
		return partErr
	}
	if partErr == nil && !partInfo.Mode().IsRegular() {
		return ErrType
	}
	metaInfo, metaErr := root.Lstat(metaPath)
	if metaErr != nil && !errors.Is(metaErr, fs.ErrNotExist) {
		return metaErr
	}
	if metaErr == nil && !metaInfo.Mode().IsRegular() {
		return ErrType
	}
	if errors.Is(partErr, fs.ErrNotExist) && errors.Is(metaErr, fs.ErrNotExist) {
		return fs.ErrNotExist
	}
	if s.beforeUploadRemoval != nil {
		s.beforeUploadRemoval()
	}
	if err := root.Remove(partPath); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if err := syncUploadsRoot(s, root); err != nil {
		return err
	}
	if err := root.Remove(metaPath); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return syncUploadsRoot(s, root)
}
