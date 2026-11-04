package backup

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path"
	"sort"
	"strings"
)

// ListMetadataRollbacks is a bounded read-only inventory. It verifies the
// retained before/after bytes but never opens or mutates the active databases,
// so the native UI can query it while Core is running.
func ListMetadataRollbacks(dataDir string) (OfflineRollbackList, error) {
	result := OfflineRollbackList{SchemaVersion: 1, Operation: "list", Transactions: []RollbackTransaction{}}
	if _, err := os.Lstat(dataDir); errors.Is(err, os.ErrNotExist) {
		return result, nil
	} else if err != nil {
		return result, err
	}
	if err := validatePrivateOwnedDir(dataDir); err != nil {
		return result, err
	}
	lock, lockErr := LockDataDir(dataDir)
	if lockErr == nil {
		defer lock.Close()
	} else if errors.Is(lockErr, ErrAppRunning) {
		result.CoreRunning = true
	} else {
		return result, lockErr
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
	if _, err := root.Lstat(activationJournalName); err == nil {
		result.MetadataRecoveryPending = true
	} else if !errors.Is(err, os.ErrNotExist) {
		return result, err
	}
	if _, err := root.Lstat(revokeRecoverySessionsName); err == nil {
		result.SessionCleanupPending = true
	} else if !errors.Is(err, os.ErrNotExist) {
		return result, err
	}
	result.RecoveryPending = result.MetadataRecoveryPending || result.SessionCleanupPending
	var pending activationPlan
	if result.MetadataRecoveryPending {
		pending, _ = readPendingJournal(root)
	}
	readDir, err := root.Open(".")
	if err != nil {
		return result, err
	}
	defer readDir.Close()
	remaining := rollbackListHashBudget
	// Always inspect the active transaction first. Large legacy histories must
	// not consume the list/hash budget before the one actionable version.
	if activeTransaction != "" {
		record := RollbackTransaction{ID: activeTransaction, State: "not_eligible", Reason: "receipt_missing"}
		receipt, receiptErr := loadRollbackReceipt(root, rollbackPrefix+activeTransaction, &remaining, false)
		if receiptErr != nil {
			record.Reason = receiptReason(receiptErr)
			if !errors.Is(receiptErr, errVerificationBudget) && !errors.Is(receiptErr, os.ErrNotExist) {
				record.State = "invalid"
			}
		} else {
			record.ActivatedAt, record.FileCount = receipt.ActivatedAt, len(receipt.Files)
			if receipt.State == rollbackStateActivated && !result.MetadataRecoveryPending {
				record.State, record.CanRollback, record.Reason = "eligible", true, ""
			} else if receipt.State == rollbackStateRolledBack {
				record.State, record.Reason = rollbackStateRolledBack, "already_rolled_back"
			}
		}
		if result.MetadataRecoveryPending {
			record.State, record.CanRollback, record.Reason = "interrupted", false, "interrupted_recovery_required"
		}
		result.Transactions = append(result.Transactions, record)
	}
	seen := 0
	for {
		entries, readErr := readDir.ReadDir(128)
		if len(entries) == 0 {
			if errors.Is(readErr, io.EOF) {
				break
			}
			if readErr != nil {
				return result, readErr
			}
			break
		}
		for _, entry := range entries {
			seen++
			if seen > rollbackScanLimit {
				result.Truncated = true
				return trimRollbackList(result), nil
			}
			name := entry.Name()
			if !strings.HasPrefix(name, rollbackPrefix) {
				continue
			}
			if name == rollbackPrefix+activeTransaction {
				continue
			}
			if len(result.Transactions) >= rollbackListLimit {
				result.Truncated = true
				return trimRollbackList(result), nil
			}
			idValue := strings.TrimPrefix(name, rollbackPrefix)
			record := RollbackTransaction{ID: idValue, State: "not_eligible", Reason: "receipt_missing"}
			info, statErr := root.Lstat(name)
			if statErr != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
				record.Reason = "not_private_directory"
				result.Transactions = append(result.Transactions, record)
				continue
			}
			if !validTransactionID(idValue) {
				record.Reason = "unrecognized_rollback_name"
				result.Transactions = append(result.Transactions, record)
				continue
			}
			if _, receiptStatErr := root.Lstat(path.Join(name, rollbackReceiptName)); errors.Is(receiptStatErr, os.ErrNotExist) {
				record.Reason = "receipt_missing"
				result.Transactions = append(result.Transactions, record)
				continue
			} else if receiptStatErr != nil {
				record.State = "invalid"
				record.Reason = "receipt_or_rollback_data_invalid"
				result.Transactions = append(result.Transactions, record)
				continue
			}
			receipt, receiptErr := loadRollbackReceipt(root, name, &remaining, false)
			if receiptErr != nil {
				record.State = "not_eligible"
				record.Reason = receiptReason(receiptErr)
				if !errors.Is(receiptErr, errVerificationBudget) {
					record.State = "invalid"
				}
			} else {
				record.ActivatedAt = receipt.ActivatedAt
				record.FileCount = len(receipt.Files)
				if receipt.State == rollbackStateRolledBack {
					record.State = rollbackStateRolledBack
					record.Reason = "already_rolled_back"
				} else if idValue == activeTransaction && !result.MetadataRecoveryPending {
					record.State = "eligible"
					record.CanRollback = true
					record.Reason = ""
				} else {
					record.State = "not_eligible"
					record.Reason = "not_current_transaction"
				}
			}
			if result.MetadataRecoveryPending && pending.TransactionID == idValue {
				record.State = "interrupted"
				record.CanRollback = false
				record.Reason = "interrupted_recovery_required"
			}
			result.Transactions = append(result.Transactions, record)
		}
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			return result, readErr
		}
	}
	return trimRollbackList(result), nil
}

func trimRollbackList(result OfflineRollbackList) OfflineRollbackList {
	sort.SliceStable(result.Transactions, func(i, j int) bool {
		if result.Transactions[i].CanRollback != result.Transactions[j].CanRollback {
			return result.Transactions[i].CanRollback
		}
		return result.Transactions[i].ActivatedAt > result.Transactions[j].ActivatedAt
	})
	for len(result.Transactions) > 0 {
		encoded, err := json.Marshal(result)
		if err == nil && len(encoded) <= rollbackOutputLimit {
			return result
		}
		result.Transactions = result.Transactions[:len(result.Transactions)-1]
		result.Truncated = true
	}
	return result
}

// InspectOfflineRecovery returns a compact status summary for the native
// owner-facing repair flow. The detailed selectable records remain in list.
func InspectOfflineRecovery(dataDir string) (OfflineRecoveryInspection, error) {
	listed, err := ListMetadataRollbacks(dataDir)
	if err != nil {
		return OfflineRecoveryInspection{}, err
	}
	result := OfflineRecoveryInspection{SchemaVersion: 1, Operation: "inspect",
		CoreRunning: listed.CoreRunning, RecoveryPending: listed.RecoveryPending,
		MetadataRecoveryPending: listed.MetadataRecoveryPending,
		SessionCleanupPending:   listed.SessionCleanupPending}
	for _, record := range listed.Transactions {
		if record.CanRollback {
			result.EligibleCount++
		} else {
			result.BlockedCount++
		}
	}
	if listed.MetadataRecoveryPending {
		if root, openErr := os.OpenRoot(dataDir); openErr == nil {
			if plan, readErr := readPendingJournal(root); readErr == nil {
				result.PendingOperation = plan.Operation
				result.PendingTransactionID = plan.TransactionID
			}
			root.Close()
		}
	} else if listed.SessionCleanupPending {
		result.PendingOperation = "session_cleanup"
	}
	return result, nil
}

func captureRollbackFile(root *os.Root, name string) (rollbackJournalFile, error) {
	result := rollbackJournalFile{Name: name}
	info, err := root.Lstat(name)
	if errors.Is(err, os.ErrNotExist) {
		return result, nil
	}
	if err != nil {
		return result, err
	}
	if !info.Mode().IsRegular() {
		return result, ErrInvalid
	}
	if info.Size() > maxBytes {
		return result, ErrTooLarge
	}
	hash, size, err := hashRootFile(root, name, maxBytes)
	if err != nil {
		return result, err
	}
	result.Present = true
	result.SHA256 = hash
	result.Size = size
	return result, nil
}

func rollbackNames(files []activationFile) []string {
	names := make([]string, 0, len(files)*3)
	seen := map[string]bool{}
	for _, file := range files {
		if !seen[file.Name] {
			names = append(names, file.Name)
			seen[file.Name] = true
		}
		if strings.HasSuffix(file.Name, ".sqlite") {
			for _, suffix := range []string{"-wal", "-shm"} {
				name := file.Name + suffix
				if !seen[name] {
					names = append(names, name)
					seen[name] = true
				}
			}
		}
	}
	return names
}
