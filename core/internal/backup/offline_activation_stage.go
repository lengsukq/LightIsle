package backup

import (
	"context"
	"errors"
	"os"
	"path"
	"path/filepath"
	"time"
)

func inspectLiveAndStageEntry(
	root *os.Root,
	sourceRoot *os.Root,
	installRoot *os.Root,
	entry ManifestEntry,
	originalBytes *int64,
) (activationFile, error) {
	_, originalErr := root.Lstat(entry.Path)
	if originalErr != nil && !errors.Is(originalErr, os.ErrNotExist) {
		return activationFile{}, originalErr
	}
	var originalSHA string
	var originalSize int64
	if originalErr == nil {
		if _, err := regularFile(root, entry.Path); err != nil {
			return activationFile{}, err
		}
		var err error
		originalSHA, originalSize, err = hashRootFile(root, entry.Path, maxBytes)
		if err != nil {
			return activationFile{}, err
		}
		if originalSize > maxMetadataSnapshotBytes-*originalBytes {
			return activationFile{}, ErrTooLarge
		}
		*originalBytes += originalSize
	}
	if err := ensureNoLiveSQLiteSidecars(root, entry.Path, "offline_activation_requires_clean_sqlite_shutdown"); err != nil {
		return activationFile{}, err
	}
	if err := copyVerifiedStageEntry(sourceRoot, installRoot, entry); err != nil {
		return activationFile{}, err
	}
	return activationFile{
		Name:           entry.Path,
		SHA256:         entry.SHA256,
		Size:           entry.Size,
		HadOriginal:    originalErr == nil,
		OriginalSHA256: originalSHA,
		OriginalSize:   originalSize,
	}, nil
}

func copyVerifiedStageEntry(sourceRoot, installRoot *os.Root, entry ManifestEntry) error {
	src, err := sourceRoot.Open(entry.Path)
	if err != nil {
		return err
	}
	dst, err := installRoot.OpenFile(entry.Path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		_ = src.Close()
		return err
	}
	sha, copyErr := boundedCopy(context.Background(), dst, src, entry.Size)
	closeErr := dst.Close()
	_ = src.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	if sha != entry.SHA256 {
		return errors.New("metadata_checksum_mismatch")
	}
	return nil
}

func sanitizeAndRehashStagedFiles(installRoot *os.Root, files []activationFile) error {
	for _, entry := range files {
		if entry.Name == "accounts.sqlite" {
			if err := clearTransientCapabilities(context.Background(), filepath.Join(installRoot.Name(), entry.Name)); err != nil {
				return err
			}
			break
		}
	}
	var activeMetadataBytes int64
	for i := range files {
		if files[i].Name == "accounts.sqlite" {
			sha, size, err := hashRootFile(installRoot, files[i].Name, maxBytes)
			if err != nil {
				return err
			}
			files[i].SHA256, files[i].Size = sha, size
		}
		if files[i].Size > maxMetadataSnapshotBytes-activeMetadataBytes {
			return ErrTooLarge
		}
		activeMetadataBytes += files[i].Size
	}
	return nil
}

func swapStagedMetadataLive(
	root *os.Root,
	installRoot *os.Root,
	rollbackRoot *os.Root,
	p activationPlan,
) error {
	for _, entry := range p.Files {
		if entry.HadOriginal {
			if err := renameAndSyncDirs(root, entry.Name, path.Join(p.Rollback, entry.Name), rollbackRoot, root); err != nil {
				_ = undoActivation(root, p)
				return err
			}
		}
		if err := renameAndSyncDirs(root, path.Join(p.Install, entry.Name), entry.Name, root, installRoot); err != nil {
			_ = undoActivation(root, p)
			return err
		}
	}
	return nil
}

func publishActivatedMetadataState(root *os.Root, p activationPlan) error {
	receipt := metadataRollbackReceipt{
		Version:               1,
		TransactionID:         p.TransactionID,
		Stage:                 p.Stage,
		PreviousTransactionID: p.PreviousTransactionID,
		ActivatedAt:           time.Now().UTC().Unix(),
		State:                 rollbackStateActivated,
		Files:                 append([]activationFile(nil), p.Files...),
	}
	if err := writeRollbackReceipt(root, p.Rollback, receipt); err != nil {
		return err
	}
	return finalizeMetadataJournalState(root, p.TransactionID, p.Install, true)
}
