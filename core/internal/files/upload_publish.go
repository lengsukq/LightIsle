package files

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
)

// FinishUpload publishes the completed part exactly once. The staged inode's
// device and inode are durably recorded before an exclusive rename moves it to
// the destination. Recovery can therefore distinguish our moved file from an
// unrelated destination without ever changing a published inode.
func (s *Store) FinishUpload(id string, owner int64) error {
	s.uploadMu.Lock()
	defer s.uploadMu.Unlock()
	meta, err := s.uploadInfo(id, owner)
	if err != nil {
		return err
	}
	if meta.Offset != meta.Size {
		return ErrOffset
	}
	if _, err := s.safePath(meta.Path, false, true); err != nil {
		return err
	}
	if meta.Published {
		return s.finishPublishedUpload(meta)
	}
	root, _, err := s.openExistingUploadsRoot()
	if err != nil {
		return err
	}
	if root == nil {
		return fs.ErrNotExist
	}
	part, partInfo, err := s.openUploadPart(root, id, os.O_RDWR, nil, meta.sourceIdentity)
	if err != nil {
		return err
	}
	identity, ok := uploadIdentity(partInfo)
	if !ok {
		_ = part.Close()
		return ErrUploadCorrupt
	}
	if meta.sourceIdentity != nil && !sameUploadSource(meta.sourceIdentity, &identity) {
		_ = part.Close()
		return ErrUploadCorrupt
	}
	if partInfo.Size() != meta.Size {
		_ = part.Close()
		return ErrSize
	}
	if err := validateOpenedUploadPart(part, partInfo, &identity); err != nil {
		_ = part.Close()
		return err
	}
	syncErr := s.syncFileContents(part)
	closeErr := part.Close()
	if syncErr != nil {
		return syncErr
	}
	if closeErr != nil {
		return closeErr
	}
	if meta.sourceIdentity == nil {
		meta.sourceIdentity = &identity
		if _, err := s.persistUpload(meta); err != nil {
			return fmt.Errorf("upload_publish_identity_sync_failed: %w", err)
		}
	}
	if err := s.renameUploadPartNoReplace(id, meta.Path); err != nil {
		if errors.Is(err, ErrExists) {
			return fmt.Errorf("%w: destination is owned by another file; abort the upload to release staging", ErrExists)
		}
		return err
	}
	if err := s.syncDirectory(path.Dir(meta.Path)); err != nil {
		return fmt.Errorf("%w: %v", ErrPublishedSync, err)
	}
	if err := syncUploadsRoot(s, root); err != nil {
		return fmt.Errorf("%w: %v", ErrPublishedSync, err)
	}
	meta.Published = true
	if _, err := s.persistUpload(meta); err != nil {
		return fmt.Errorf("%w: published marker write: %w", ErrPublishedSync, err)
	}
	return s.finishPublishedUpload(meta)
}

// finishPublishedUpload removes the staging journal only after the destination
// is known to be the published inode. It is safe to call repeatedly.
func (s *Store) finishPublishedUpload(meta UploadState) error {
	root, _, err := s.openExistingUploadsRoot()
	if err != nil {
		return err
	}
	if root == nil {
		return fs.ErrNotExist
	}
	partPath := meta.ID + ".part"
	metaPath := meta.ID + ".json"
	destInfo, err := s.root.Lstat(meta.Path)
	switch {
	case err == nil:
		if !destInfo.Mode().IsRegular() {
			return ErrType
		}
		partInfo, partErr := root.Lstat(partPath)
		if partErr == nil {
			if !partInfo.Mode().IsRegular() {
				return ErrType
			}
			if !os.SameFile(partInfo, destInfo) {
				return fmt.Errorf("%w: published destination belongs to another file; abort to release staging", ErrExists)
			}
		} else if errors.Is(partErr, fs.ErrNotExist) && meta.sourceIdentity != nil && !sameUploadInode(meta.sourceIdentity, destInfo) {
			return uploadOutcomeUncertain("destination identity does not match the published upload")
		} else if errors.Is(partErr, fs.ErrNotExist) && meta.sourceIdentity == nil {
			return uploadOutcomeUncertain("legacy published destination has no staged inode to verify it")
		} else if !errors.Is(partErr, fs.ErrNotExist) {
			return partErr
		}
	case errors.Is(err, fs.ErrNotExist):
		partInfo, partErr := root.Lstat(partPath)
		if errors.Is(partErr, fs.ErrNotExist) {
			return uploadOutcomeUncertain("published upload has neither destination nor staged part")
		}
		if partErr != nil {
			return partErr
		}
		if !partInfo.Mode().IsRegular() {
			return ErrType
		}
		if err := validatePrivateUploadPart(partInfo); err != nil {
			return err
		}
		identity, ok := uploadIdentity(partInfo)
		if !ok {
			return ErrUploadCorrupt
		}
		if meta.sourceIdentity != nil && !sameUploadSource(meta.sourceIdentity, &identity) {
			return ErrUploadCorrupt
		}
		if meta.sourceIdentity == nil {
			meta.sourceIdentity = &identity
			if _, persistErr := s.persistUpload(meta); persistErr != nil {
				return fmt.Errorf("%w: %v", ErrPublishedSync, persistErr)
			}
		}
		if err := s.renameUploadPartNoReplace(meta.ID, meta.Path); err != nil {
			return err
		}
		if syncErr := s.syncDirectory(path.Dir(meta.Path)); syncErr != nil {
			return fmt.Errorf("%w: %v", ErrPublishedSync, syncErr)
		}
		if syncErr := syncUploadsRoot(s, root); syncErr != nil {
			return fmt.Errorf("%w: %v", ErrPublishedSync, syncErr)
		}
		if _, persistErr := s.persistUpload(meta); persistErr != nil {
			return fmt.Errorf("%w: %v", ErrPublishedSync, persistErr)
		}
	default:
		return err
	}
	if removeErr := root.Remove(partPath); removeErr != nil && !errors.Is(removeErr, fs.ErrNotExist) {
		return removeErr
	}
	if syncErr := syncUploadsRoot(s, root); syncErr != nil {
		return syncErr
	}
	if removeErr := root.Remove(metaPath); removeErr != nil && !errors.Is(removeErr, fs.ErrNotExist) {
		return removeErr
	}
	return syncUploadsRoot(s, root)
}

// AbortUpload discards the staging part and journal for its owner. A published
// destination has been moved out of staging, so aborting never touches it;
// this is also the owner-accessible cleanup for a published journal that
// FinishUpload cannot reconcile.
func (s *Store) AbortUpload(id string, owner int64) error {
	s.uploadMu.Lock()
	defer s.uploadMu.Unlock()
	return s.abortUpload(id, owner)
}

// AbortUploadWithAccounting holds the upload lock while deciding whether
// staging is definitely unpublished. Ambiguous results remain reserved.
func (s *Store) AbortUploadWithAccounting(id string, owner int64) (bool, error) {
	s.uploadMu.Lock()
	defer s.uploadMu.Unlock()
	root, _, err := s.openExistingUploadsRoot()
	if err != nil {
		return false, err
	}
	if root == nil {
		return false, fs.ErrNotExist
	}
	meta, err := readUploadJournalFrom(root, id)
	if err != nil {
		return false, err
	}
	if meta.Owner != owner {
		return false, ErrOwner
	}
	safe := s.uploadDefinitelyUnpublished(root, id, meta)
	if err := s.abortUpload(id, owner); err != nil {
		return false, err
	}
	return safe, nil
}

func (s *Store) uploadDefinitelyUnpublished(root *os.Root, id string, meta UploadState) bool {
	if meta.Published {
		return false
	}
	part, err := root.Lstat(id + ".part")
	if err != nil || !part.Mode().IsRegular() {
		return false
	}
	name, err := s.safePath(meta.Path, false, true)
	if err != nil {
		return false
	}
	_, err = s.root.Lstat(name)
	return errors.Is(err, fs.ErrNotExist)
}

func (s *Store) abortUpload(id string, owner int64) error {
	root, _, err := s.openExistingUploadsRoot()
	if err != nil {
		return err
	}
	if root == nil {
		return fs.ErrNotExist
	}
	meta, err := readUploadJournalFrom(root, id)
	if err != nil {
		return err
	}
	if meta.Owner != owner {
		return ErrOwner
	}
	partPath := id + ".part"
	if info, statErr := root.Lstat(partPath); statErr == nil {
		if !info.Mode().IsRegular() {
			return ErrType
		}
	} else if !errors.Is(statErr, fs.ErrNotExist) {
		return statErr
	}
	if err := root.Remove(partPath); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if err := syncUploadsRoot(s, root); err != nil {
		return err
	}
	if err := root.Remove(id + ".json"); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return syncUploadsRoot(s, root)
}
