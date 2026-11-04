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
	"strings"
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
	activeTransaction, err := readActiveMetadata(root)
	if err != nil {
		return result, err
	}
	if activeTransaction != transactionID {
		return result, errors.New("rollback_not_eligible_not_current_transaction")
	}
	rollbackDir := rollbackPrefix + transactionID
	receipt, err := loadRollbackReceipt(root, rollbackDir, nil, false)
	if err != nil {
		return result, err
	}
	if receipt.State != rollbackStateActivated {
		return result, errors.New("rollback_not_eligible")
	}
	if _, err := root.Lstat(path.Join(rollbackDir, rollbackAfterName)); err == nil {
		return result, errors.New("rollback_after_already_exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return result, err
	}
	journalFiles := make([]rollbackJournalFile, 0, len(receipt.Files)*3)
	var capturedBytes int64
	for _, name := range rollbackNames(receipt.Files) {
		entry, err := captureRollbackFile(root, name)
		if err != nil {
			return result, fmt.Errorf("capture current metadata %s: %w", name, err)
		}
		if entry.Present {
			if entry.Size > maxMetadataSnapshotBytes-capturedBytes {
				return result, ErrTooLarge
			}
			capturedBytes += entry.Size
		}
		journalFiles = append(journalFiles, entry)
	}
	install := rollbackInstallPrefix + transactionID
	if _, err := root.Lstat(install); err == nil {
		return result, errors.New("rollback_install_already_exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return result, err
	}
	plan := activationPlan{Operation: "rollback", TransactionID: transactionID, Stage: receipt.Stage,
		PreviousTransactionID: receipt.PreviousTransactionID,
		Install:               install, Rollback: rollbackDir, Files: append([]activationFile(nil), receipt.Files...),
		RollbackFiles: journalFiles}
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

func undoMetadataRollback(root *os.Root, plan activationPlan) error {
	if plan.Operation != "rollback" || !validTransactionID(plan.TransactionID) ||
		plan.Rollback != rollbackPrefix+plan.TransactionID || plan.Install != rollbackInstallPrefix+plan.TransactionID {
		return ErrInvalid
	}
	receipt, err := loadRollbackReceipt(root, plan.Rollback, nil, true)
	if err != nil {
		return err
	}
	if receipt.TransactionID != plan.TransactionID || !sameActivationFiles(receipt.Files, plan.Files) {
		return errors.New("rollback_receipt_journal_mismatch")
	}
	if receipt.PreviousTransactionID != plan.PreviousTransactionID {
		return errors.New("rollback_previous_transaction_mismatch")
	}
	afterPath := path.Join(plan.Rollback, rollbackAfterName)
	if _, err := root.Lstat(afterPath); errors.Is(err, os.ErrNotExist) {
		rollbackRoot, openErr := root.OpenRoot(plan.Rollback)
		if openErr != nil {
			return openErr
		}
		openErr = rollbackRoot.Mkdir(rollbackAfterName, 0700)
		closeErr := rollbackRoot.Close()
		if openErr != nil {
			return openErr
		}
		if closeErr != nil {
			return closeErr
		}
		if err := syncPrivateDir(root); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	after, err := root.OpenRoot(afterPath)
	if err != nil {
		return err
	}
	defer after.Close()

	beforeByName := make(map[string]activationFile, len(plan.Files))
	for _, before := range plan.Files {
		beforeByName[before.Name] = before
	}
	for _, current := range plan.RollbackFiles {
		archivedName := current.Name
		archivedInfo, archivedErr := after.Lstat(archivedName)
		liveInfo, liveErr := root.Lstat(current.Name)
		if current.Present {
			if archivedErr == nil {
				if !archivedInfo.Mode().IsRegular() {
					return errors.New("rollback_after_file_invalid")
				}
				if err := verifyRootFile(after, archivedName, current.SHA256, current.Size, nil); err != nil {
					return err
				}
				if liveErr == nil {
					if err := currentIsRestored(root, current.Name, liveInfo, beforeByName); err != nil {
						return err
					}
				} else if !errors.Is(liveErr, os.ErrNotExist) {
					return liveErr
				}
				continue
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
			if err := root.Rename(current.Name, path.Join(afterPath, current.Name)); err != nil {
				return err
			}
			if err := syncPrivateDir(root); err != nil {
				return err
			}
			if err := syncPrivateDir(after); err != nil {
				return err
			}
		} else {
			if archivedErr == nil {
				return errors.New("rollback_unexpected_after_file")
			}
			if !errors.Is(archivedErr, os.ErrNotExist) {
				return archivedErr
			}
			if liveErr == nil {
				if err := currentIsRestored(root, current.Name, liveInfo, beforeByName); err != nil {
					return err
				}
			} else if !errors.Is(liveErr, os.ErrNotExist) {
				return liveErr
			}
		}
	}
	if err := syncPrivateDir(root); err != nil {
		return err
	}

	installInfo, installErr := root.Lstat(plan.Install)
	if errors.Is(installErr, os.ErrNotExist) {
		if err := root.Mkdir(plan.Install, 0700); err != nil {
			return err
		}
		installInfo = nil
	} else if installErr != nil {
		return installErr
	} else if !installInfo.IsDir() || installInfo.Mode()&os.ModeSymlink != 0 || installInfo.Mode().Perm()&0077 != 0 {
		return errors.New("rollback_install_directory_invalid")
	}
	installRoot, err := root.OpenRoot(plan.Install)
	if err != nil {
		return err
	}
	defer installRoot.Close()
	rollbackRoot, err := root.OpenRoot(plan.Rollback)
	if err != nil {
		return err
	}
	defer rollbackRoot.Close()
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
		if err := root.Rename(path.Join(plan.Install, before.Name), before.Name); err != nil {
			return err
		}
		if err := syncPrivateDir(root); err != nil {
			return err
		}
	}
	for _, before := range plan.Files {
		if before.HadOriginal {
			if err := verifyRootFile(root, before.Name, before.OriginalSHA256, before.OriginalSize, nil); err != nil {
				return err
			}
		}
		if strings.HasSuffix(before.Name, ".sqlite") {
			for _, suffix := range []string{"-wal", "-shm"} {
				if _, err := root.Lstat(before.Name + suffix); err == nil {
					return errors.New("rollback_sqlite_sidecar_remains_live")
				} else if !errors.Is(err, os.ErrNotExist) {
					return err
				}
			}
		}
	}
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
	if err := writeActiveMetadata(root, receipt.PreviousTransactionID); err != nil {
		return err
	}
	if err := markRecoverySessionRevocation(root); err != nil {
		return err
	}
	if err := root.RemoveAll(plan.Install); err != nil {
		return err
	}
	if err := syncPrivateDir(root); err != nil {
		return err
	}
	if err := root.Remove(activationJournalName); err != nil {
		return err
	}
	return syncPrivateDir(root)
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
