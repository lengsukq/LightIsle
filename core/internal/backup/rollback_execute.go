package backup

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"time"
)

// RollbackMetadata performs an owner-authorized caller's offline rollback. The
// helper itself requires the exclusive data lock, so it cannot run while Core
// is using SQLite. Current databases and SQLite sidecars are retained under
// the transaction's after/ directory before any previous version is restored.
func RollbackMetadata(dataDir, transactionID string) (OfflineRollbackResult, error) {
	result := OfflineRollbackResult{SchemaVersion: 1, Operation: "rollback", Status: "failed", TransactionID: transactionID}
	if !validTransactionID(transactionID) {
		return result, errors.New("invalid_transaction_id")
	}
	if err := validatePrivateOwnedDir(dataDir); err != nil {
		return result, err
	}
	lock, err := LockDataDir(dataDir)
	if err != nil {
		return result, err
	}
	defer lock.Close()
	if err := validatePrivateOwnedDir(dataDir); err != nil {
		return result, err
	}
	if MetadataActivationPending(dataDir) {
		return result, errors.New("interrupted_recovery_pending")
	}
	root, err := os.OpenRoot(dataDir)
	if err != nil {
		return result, err
	}
	defer root.Close()

	rollbackDir := rollbackPrefix + transactionID
	plan, receipt, err := prepareRollbackJournalPlan(root, transactionID, rollbackDir)
	if err != nil {
		return result, err
	}
	if err := saveActivationPlan(root, activationJournalName, plan); err != nil {
		return result, err
	}
	if err := undoMetadataRollback(root, plan); err != nil {
		result.RecoveryPending = RecoveryPending(dataDir)
		return result, err
	}
	if err := FinalizeRecoverySessions(dataDir); err != nil {
		return result, err
	}
	result.Status = rollbackStateRolledBack
	result.PreservedCurrent = filepath.Join(dataDir, rollbackDir, rollbackAfterName)
	for _, file := range receipt.Files {
		if file.HadOriginal {
			result.RestoredPrevious = append(result.RestoredPrevious, file.Name)
		}
	}
	return result, nil
}

func prepareRollbackJournalPlan(
	root *os.Root,
	transactionID string,
	rollbackDir string,
) (activationPlan, metadataRollbackReceipt, error) {
	activeTransaction, err := readActiveMetadata(root)
	if err != nil {
		return activationPlan{}, metadataRollbackReceipt{}, err
	}
	if activeTransaction != transactionID {
		return activationPlan{}, metadataRollbackReceipt{}, errors.New("rollback_not_eligible_not_current_transaction")
	}
	receipt, err := loadRollbackReceipt(root, rollbackDir, nil, false)
	if err != nil {
		return activationPlan{}, metadataRollbackReceipt{}, err
	}
	if receipt.State != rollbackStateActivated {
		return activationPlan{}, metadataRollbackReceipt{}, errors.New("rollback_not_eligible")
	}
	if _, err := root.Lstat(path.Join(rollbackDir, rollbackAfterName)); err == nil {
		return activationPlan{}, metadataRollbackReceipt{}, errors.New("rollback_after_already_exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return activationPlan{}, metadataRollbackReceipt{}, err
	}
	journalFiles, err := captureRollbackLiveSnapshot(root, receipt.Files)
	if err != nil {
		return activationPlan{}, metadataRollbackReceipt{}, err
	}
	install := rollbackInstallPrefix + transactionID
	if _, err := root.Lstat(install); err == nil {
		return activationPlan{}, metadataRollbackReceipt{}, errors.New("rollback_install_already_exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return activationPlan{}, metadataRollbackReceipt{}, err
	}
	plan := activationPlan{
		Operation:             "rollback",
		TransactionID:         transactionID,
		Stage:                 receipt.Stage,
		PreviousTransactionID: receipt.PreviousTransactionID,
		Install:               install,
		Rollback:              rollbackDir,
		Files:                 append([]activationFile(nil), receipt.Files...),
		RollbackFiles:         journalFiles,
	}
	return plan, receipt, nil
}

func captureRollbackLiveSnapshot(root *os.Root, files []activationFile) ([]rollbackJournalFile, error) {
	names := rollbackNames(files)
	journalFiles := make([]rollbackJournalFile, 0, len(names))
	var capturedBytes int64
	for _, name := range names {
		entry, err := captureRollbackFile(root, name)
		if err != nil {
			return nil, fmt.Errorf("capture current metadata %s: %w", name, err)
		}
		if entry.Present {
			if entry.Size > maxMetadataSnapshotBytes-capturedBytes {
				return nil, ErrTooLarge
			}
			capturedBytes += entry.Size
		}
		journalFiles = append(journalFiles, entry)
	}
	return journalFiles, nil
}

func undoMetadataRollback(root *os.Root, plan activationPlan) error {
	receipt, err := loadVerifiedRollbackReceiptForRecovery(root, plan)
	if err != nil {
		return err
	}
	after, afterPath, err := openOrCreateRollbackAfterRoot(root, plan.Rollback)
	if err != nil {
		return err
	}
	defer after.Close()

	if err := archiveDisplacedRollbackFiles(root, after, afterPath, plan); err != nil {
		return err
	}
	installRoot, err := openOrCreateRollbackInstallRoot(root, plan.Install)
	if err != nil {
		return err
	}
	defer installRoot.Close()

	rollbackRoot, err := root.OpenRoot(plan.Rollback)
	if err != nil {
		return err
	}
	defer rollbackRoot.Close()

	if err := restorePreviousRollbackOriginals(root, installRoot, rollbackRoot, plan); err != nil {
		return err
	}
	if err := verifyRolledBackLiveState(root, plan.Files); err != nil {
		return err
	}
	return finalizeRollbackReceiptAndJournal(root, plan, receipt)
}

func loadVerifiedRollbackReceiptForRecovery(
	root *os.Root,
	plan activationPlan,
) (metadataRollbackReceipt, error) {
	if plan.Operation != "rollback" || !validTransactionID(plan.TransactionID) ||
		plan.Rollback != rollbackPrefix+plan.TransactionID ||
		plan.Install != rollbackInstallPrefix+plan.TransactionID {
		return metadataRollbackReceipt{}, ErrInvalid
	}
	receipt, err := loadRollbackReceipt(root, plan.Rollback, nil, true)
	if err != nil {
		return metadataRollbackReceipt{}, err
	}
	if receipt.TransactionID != plan.TransactionID || !sameActivationFiles(receipt.Files, plan.Files) {
		return metadataRollbackReceipt{}, errors.New("rollback_receipt_journal_mismatch")
	}
	if receipt.PreviousTransactionID != plan.PreviousTransactionID {
		return metadataRollbackReceipt{}, errors.New("rollback_previous_transaction_mismatch")
	}
	return receipt, nil
}

func openOrCreateRollbackAfterRoot(root *os.Root, rollbackDir string) (*os.Root, string, error) {
	afterPath := path.Join(rollbackDir, rollbackAfterName)
	if _, err := root.Lstat(afterPath); errors.Is(err, os.ErrNotExist) {
		rollbackRoot, openErr := root.OpenRoot(rollbackDir)
		if openErr != nil {
			return nil, "", openErr
		}
		mkdirErr := rollbackRoot.Mkdir(rollbackAfterName, 0700)
		closeErr := rollbackRoot.Close()
		if mkdirErr != nil {
			return nil, "", mkdirErr
		}
		if closeErr != nil {
			return nil, "", closeErr
		}
		if err := syncPrivateDir(root); err != nil {
			return nil, "", err
		}
	} else if err != nil {
		return nil, "", err
	}
	after, err := root.OpenRoot(afterPath)
	if err != nil {
		return nil, "", err
	}
	return after, afterPath, nil
}

func archiveDisplacedRollbackFiles(
	root *os.Root,
	after *os.Root,
	afterPath string,
	plan activationPlan,
) error {
	beforeByName := make(map[string]activationFile, len(plan.Files))
	for _, before := range plan.Files {
		beforeByName[before.Name] = before
	}
	for _, current := range plan.RollbackFiles {
		if err := archiveSingleRollbackFile(root, after, afterPath, current, beforeByName); err != nil {
			return err
		}
	}
	return syncPrivateDir(root)
}

func archiveSingleRollbackFile(
	root *os.Root,
	after *os.Root,
	afterPath string,
	current rollbackJournalFile,
	beforeByName map[string]activationFile,
) error {
	archivedInfo, archivedErr := after.Lstat(current.Name)
	liveInfo, liveErr := root.Lstat(current.Name)
	if !current.Present {
		if archivedErr == nil {
			return errors.New("rollback_unexpected_after_file")
		}
		if !errors.Is(archivedErr, os.ErrNotExist) {
			return archivedErr
		}
		if liveErr == nil {
			return currentIsRestored(root, current.Name, liveInfo, beforeByName)
		}
		if !errors.Is(liveErr, os.ErrNotExist) {
			return liveErr
		}
		return nil
	}
	if archivedErr == nil {
		if !archivedInfo.Mode().IsRegular() {
			return errors.New("rollback_after_file_invalid")
		}
		if err := verifyRootFile(after, current.Name, current.SHA256, current.Size, nil); err != nil {
			return err
		}
		if liveErr == nil {
			return currentIsRestored(root, current.Name, liveInfo, beforeByName)
		}
		if !errors.Is(liveErr, os.ErrNotExist) {
			return liveErr
		}
		return nil
	}
	if !errors.Is(archivedErr, os.ErrNotExist) {
		return archivedErr
	}
	if liveErr != nil {
		if !errors.Is(liveErr, os.ErrNotExist) {
			return liveErr
		}
		return errors.New("rollback_current_file_missing")
	}
	if !liveInfo.Mode().IsRegular() {
		return ErrInvalid
	}
	if err := verifyRootFile(root, current.Name, current.SHA256, current.Size, nil); err != nil {
		return err
	}
	return renameAndSyncDirs(root, current.Name, path.Join(afterPath, current.Name), root, after)
}

func openOrCreateRollbackInstallRoot(root *os.Root, installDir string) (*os.Root, error) {
	if _, installErr := root.Lstat(installDir); errors.Is(installErr, os.ErrNotExist) {
		if err := root.Mkdir(installDir, 0700); err != nil {
			return nil, err
		}
		return root.OpenRoot(installDir)
	} else if installErr != nil {
		return nil, installErr
	}
	return openOwnedPrivateSubroot(root, installDir, "rollback_install_directory_invalid", "")
}

func restorePreviousRollbackOriginals(
	root *os.Root,
	installRoot *os.Root,
	rollbackRoot *os.Root,
	plan activationPlan,
) error {
	for _, before := range plan.Files {
		_, liveErr := root.Lstat(before.Name)
		if !before.HadOriginal {
			if liveErr == nil {
				return errors.New("rollback_new_file_not_removed")
			}
			if !errors.Is(liveErr, os.ErrNotExist) {
				return liveErr
			}
			continue
		}
		if liveErr == nil {
			if err := verifyRootFile(root, before.Name, before.OriginalSHA256, before.OriginalSize, nil); err != nil {
				return errors.New("rollback_live_file_changed_during_recovery")
			}
			continue
		}
		if !errors.Is(liveErr, os.ErrNotExist) {
			return liveErr
		}
		if err := stageAndRestoreRollbackFile(root, installRoot, rollbackRoot, plan.Install, before); err != nil {
			return err
		}
	}
	return nil
}

func stageAndRestoreRollbackFile(
	root *os.Root,
	installRoot *os.Root,
	rollbackRoot *os.Root,
	installDir string,
	before activationFile,
) error {
	staged := false
	if _, err := installRoot.Lstat(before.Name); err == nil {
		if verifyRootFile(installRoot, before.Name, before.OriginalSHA256, before.OriginalSize, nil) == nil {
			staged = true
		} else if err := installRoot.Remove(before.Name); err != nil {
			return err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if !staged {
		if err := copyRootFile(rollbackRoot, before.Name, installRoot, before.Name, before.OriginalSHA256, before.OriginalSize); err != nil {
			return err
		}
	}
	if err := root.Rename(path.Join(installDir, before.Name), before.Name); err != nil {
		return err
	}
	return syncPrivateDir(root)
}

func verifyRolledBackLiveState(root *os.Root, files []activationFile) error {
	for _, before := range files {
		if before.HadOriginal {
			if err := verifyRootFile(root, before.Name, before.OriginalSHA256, before.OriginalSize, nil); err != nil {
				return err
			}
		}
		if err := ensureNoLiveSQLiteSidecars(root, before.Name, "rollback_sqlite_sidecar_remains_live"); err != nil {
			return err
		}
	}
	return nil
}

func finalizeRollbackReceiptAndJournal(
	root *os.Root,
	plan activationPlan,
	receipt metadataRollbackReceipt,
) error {
	if receipt.State == rollbackStateActivated {
		receipt.State = rollbackStateRolledBack
		receipt.RolledBackAt = time.Now().UTC().Unix()
		receipt.AfterDirectory = rollbackAfterName
		receipt.AfterFiles = receiptFiles(plan.RollbackFiles)
	} else if !sameRollbackReceiptFiles(receipt.AfterFiles, receiptFiles(plan.RollbackFiles)) {
		return errors.New("rollback_receipt_after_mismatch")
	}
	if err := writeRollbackReceipt(root, plan.Rollback, receipt); err != nil {
		return err
	}
	return finalizeMetadataJournalState(root, receipt.PreviousTransactionID, plan.Install, false)
}

func currentIsRestored(root *os.Root, name string, info os.FileInfo, before map[string]activationFile) error {
	if !info.Mode().IsRegular() {
		return errors.New("rollback_unexpected_live_file")
	}
	entry, ok := before[name]
	if !ok || !entry.HadOriginal {
		return errors.New("rollback_unexpected_live_file")
	}
	if err := verifyRootFile(root, name, entry.OriginalSHA256, entry.OriginalSize, nil); err != nil {
		return errors.New("rollback_live_file_changed_during_recovery")
	}
	return nil
}

func copyRootFile(src *os.Root, srcName string, dst *os.Root, dstName, expectedSHA string, expectedSize int64) error {
	info, err := regularFile(src, srcName)
	if err != nil {
		return err
	}
	if expectedSize < 0 || info.Size() != expectedSize {
		return ErrInvalid
	}
	in, err := openCheckedBackupFile(src, srcName, info)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := dst.OpenFile(dstName, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	h := sha256.New()
	n, copyErr := io.Copy(io.MultiWriter(out, h), io.LimitReader(in, expectedSize+1))
	if copyErr == nil && (n != expectedSize || hex.EncodeToString(h.Sum(nil)) != expectedSHA) {
		copyErr = errors.New("metadata_checksum_mismatch")
	}
	if copyErr == nil {
		copyErr = out.Sync()
	}
	closeErr := out.Close()
	if copyErr != nil {
		_ = dst.Remove(dstName)
		return copyErr
	}
	if closeErr != nil {
		_ = dst.Remove(dstName)
		return closeErr
	}
	return syncPrivateDir(dst)
}

func receiptFiles(files []rollbackJournalFile) []rollbackReceiptFile {
	result := make([]rollbackReceiptFile, 0, len(files))
	for _, file := range files {
		if file.Present {
			result = append(result, rollbackReceiptFile{Name: file.Name, SHA256: file.SHA256, Size: file.Size})
		}
	}
	return result
}

func sameActivationFiles(a, b []activationFile) bool {
	if len(a) != len(b) {
		return false
	}
	left := make(map[string]activationFile, len(a))
	for _, file := range a {
		left[file.Name] = file
	}
	for _, file := range b {
		if left[file.Name] != file {
			return false
		}
	}
	return true
}

func sameRollbackReceiptFiles(a, b []rollbackReceiptFile) bool {
	if len(a) != len(b) {
		return false
	}
	left := make(map[string]rollbackReceiptFile, len(a))
	for _, file := range a {
		left[file.Name] = file
	}
	for _, file := range b {
		if left[file.Name] != file {
			return false
		}
	}
	return true
}
