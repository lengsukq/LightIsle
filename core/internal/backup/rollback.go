package backup

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

const (
	rollbackReceiptName     = "metadata-activation-receipt.json"
	rollbackAfterName       = "after"
	rollbackInstallPrefix   = ".lightisle-rollback-install-"
	rollbackStateActivated  = "activated"
	rollbackStateRolledBack = "rolled_back"
	rollbackListLimit       = 64
	rollbackScanLimit       = 4096
	rollbackOutputLimit     = 256 << 10
	rollbackListHashBudget  = int64(256 << 20)
)

var errVerificationBudget = errors.New("rollback_verification_budget_exceeded")

type metadataRollbackReceipt struct {
	PreviousTransactionID string                `json:"previousTransactionId,omitempty"`
	Version               int                   `json:"version"`
	TransactionID         string                `json:"transactionId"`
	Stage                 string                `json:"stage"`
	ActivatedAt           int64                 `json:"activatedAt"`
	State                 string                `json:"state"`
	Files                 []activationFile      `json:"files"`
	RolledBackAt          int64                 `json:"rolledBackAt,omitempty"`
	AfterDirectory        string                `json:"afterDirectory,omitempty"`
	AfterFiles            []rollbackReceiptFile `json:"afterFiles,omitempty"`
}

type rollbackReceiptFile struct {
	Name   string `json:"name"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type rollbackJournalFile struct {
	Name    string `json:"name"`
	Present bool   `json:"present"`
	SHA256  string `json:"sha256,omitempty"`
	Size    int64  `json:"size,omitempty"`
}

type RollbackTransaction struct {
	ID          string `json:"id"`
	State       string `json:"state"`
	CanRollback bool   `json:"canRollback"`
	Reason      string `json:"reason,omitempty"`
	ActivatedAt int64  `json:"activatedAt"`
	FileCount   int    `json:"fileCount"`
}

type OfflineRollbackList struct {
	SchemaVersion           int                   `json:"schemaVersion"`
	Operation               string                `json:"operation"`
	Transactions            []RollbackTransaction `json:"transactions"`
	Truncated               bool                  `json:"truncated"`
	CoreRunning             bool                  `json:"coreRunning"`
	RecoveryPending         bool                  `json:"recoveryPending"`
	MetadataRecoveryPending bool                  `json:"metadataRecoveryPending"`
	SessionCleanupPending   bool                  `json:"sessionCleanupPending"`
}

type OfflineRecoveryInspection struct {
	SchemaVersion           int    `json:"schemaVersion"`
	Operation               string `json:"operation"`
	CoreRunning             bool   `json:"coreRunning"`
	RecoveryPending         bool   `json:"recoveryPending"`
	MetadataRecoveryPending bool   `json:"metadataRecoveryPending"`
	SessionCleanupPending   bool   `json:"sessionCleanupPending"`
	PendingOperation        string `json:"pendingOperation,omitempty"`
	PendingTransactionID    string `json:"pendingTransactionId,omitempty"`
	EligibleCount           int    `json:"eligibleCount"`
	BlockedCount            int    `json:"blockedCount"`
}

type OfflineRollbackResult struct {
	SchemaVersion    int      `json:"schemaVersion"`
	Operation        string   `json:"operation"`
	Status           string   `json:"status"`
	TransactionID    string   `json:"transactionId,omitempty"`
	PreservedCurrent string   `json:"preservedCurrent,omitempty"`
	RestoredPrevious []string `json:"restoredPrevious,omitempty"`
	RecoveryPending  bool     `json:"recoveryPending"`
	Error            *struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

func validTransactionID(value string) bool {
	if len(value) != 16 {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == 8
}

func validSHA256(value string) bool {
	if len(value) != 64 {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size
}

func activationMetadataName(name string) bool {
	return syntacticMetadataName(name)
}

func rollbackCurrentName(name string) bool {
	if activationMetadataName(name) {
		return true
	}
	for _, suffix := range []string{"-wal", "-shm"} {
		if strings.HasSuffix(name, suffix) && activationSQLiteName(strings.TrimSuffix(name, suffix)) {
			return true
		}
	}
	return false
}

func activationSQLiteName(name string) bool {
	if _, ok := fixedMetadataTables[name]; ok {
		return true
	}
	_, ok := rootMetadataTable(name)
	return ok
}

func currentUID(info os.FileInfo) (uint32, bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return stat.Uid, true
}

// validatePrivateOwnedDir checks the selected data directory without changing
// its permissions. A private data directory is the local trust boundary for
// recovery receipts; silently chmod'ing an owner-selected existing directory
// would conceal an unsafe setup rather than repair it transparently.
func validatePrivateOwnedDir(name string) error {
	info, err := os.Lstat(name)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		return errors.New("recovery_data_directory_not_private")
	}
	uid, ok := currentUID(info)
	if !ok || uid != uint32(os.Geteuid()) {
		return errors.New("recovery_data_directory_not_owned_by_current_user")
	}
	return nil
}

func validatePrivateOwnedRegularFile(root *os.Root, name string) (os.FileInfo, error) {
	info, err := root.Lstat(name)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("recovery_receipt_not_private_regular_file")
	}
	uid, ok := currentUID(info)
	if !ok || uid != uint32(os.Geteuid()) {
		return nil, errors.New("recovery_receipt_not_owned_by_current_user")
	}
	return info, nil
}

func validateOwnedRegularFile(root *os.Root, name string) (os.FileInfo, error) {
	info, err := root.Lstat(name)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, ErrInvalid
	}
	uid, ok := currentUID(info)
	if !ok || uid != uint32(os.Geteuid()) {
		return nil, errors.New("rollback_file_not_owned_by_current_user")
	}
	return info, nil
}

func hashRootFile(root *os.Root, name string, maxSize int64) (string, int64, error) {
	info, err := regularFile(root, name)
	if err != nil {
		return "", 0, err
	}
	if info.Size() < 0 || info.Size() > maxSize {
		return "", 0, ErrTooLarge
	}
	f, err := root.Open(name)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, io.LimitReader(f, info.Size()+1))
	if err != nil {
		return "", 0, err
	}
	if n != info.Size() {
		return "", 0, errors.New("metadata_size_mismatch")
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}

func verifyRootFile(root *os.Root, name, wantSHA string, wantSize int64, byteBudget *int64) error {
	if byteBudget != nil {
		if wantSize < 0 || wantSize > *byteBudget {
			return errVerificationBudget
		}
		*byteBudget -= wantSize
	}
	gotSHA, gotSize, err := hashRootFile(root, name, maxBytes)
	if err != nil {
		return err
	}
	if gotSize != wantSize {
		return errors.New("metadata_size_mismatch")
	}
	if gotSHA != wantSHA {
		return errors.New("metadata_checksum_mismatch")
	}
	return nil
}

func atomicWritePrivate(root *os.Root, name string, data []byte) error {
	tmp := ".lightisle-receipt-" + id() + ".tmp"
	f, err := root.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	n, writeErr := f.Write(data)
	if writeErr == nil && n != len(data) {
		writeErr = io.ErrShortWrite
	}
	if writeErr == nil {
		writeErr = f.Sync()
	}
	closeErr := f.Close()
	if writeErr != nil {
		_ = root.Remove(tmp)
		return writeErr
	}
	if closeErr != nil {
		_ = root.Remove(tmp)
		return closeErr
	}
	if err := root.Rename(tmp, name); err != nil {
		_ = root.Remove(tmp)
		return err
	}
	return syncPrivateDir(root)
}

func writeRollbackReceipt(root *os.Root, rollbackDir string, receipt metadataRollbackReceipt) error {
	dirInfo, err := root.Lstat(rollbackDir)
	if err != nil {
		return err
	}
	if !dirInfo.IsDir() || dirInfo.Mode()&os.ModeSymlink != 0 || dirInfo.Mode().Perm()&0077 != 0 {
		return errors.New("rollback_directory_not_private")
	}
	uid, ok := currentUID(dirInfo)
	if !ok || uid != uint32(os.Geteuid()) {
		return errors.New("rollback_directory_not_owned_by_current_user")
	}
	if err := validateRollbackReceiptShape(rollbackDir, receipt); err != nil {
		return err
	}
	encoded, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return err
	}
	rollbackRoot, err := root.OpenRoot(rollbackDir)
	if err != nil {
		return err
	}
	defer rollbackRoot.Close()
	if _, err := rollbackRoot.Lstat(rollbackReceiptName); err == nil {
		if _, err := validatePrivateOwnedRegularFile(rollbackRoot, rollbackReceiptName); err != nil {
			return err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return atomicWritePrivate(rollbackRoot, rollbackReceiptName, encoded)
}

func validateRollbackReceiptShape(directory string, receipt metadataRollbackReceipt) error {
	if receipt.Version != 1 || !validTransactionID(receipt.TransactionID) ||
		(receipt.PreviousTransactionID != "" && (!validTransactionID(receipt.PreviousTransactionID) || receipt.PreviousTransactionID == receipt.TransactionID)) ||
		directory != rollbackPrefix+receipt.TransactionID ||
		!validActivationName(receipt.Stage, "LightIsle-RestoredMetadata-") || receipt.ActivatedAt <= 0 ||
		len(receipt.Files) == 0 || len(receipt.Files) > maxRollbackMetadataEntries {
		return ErrInvalid
	}
	seen := make(map[string]bool, len(receipt.Files))
	hasAccounts := false
	var activeBytes, originalBytes int64
	for _, file := range receipt.Files {
		if !activationMetadataName(file.Name) || seen[file.Name] || !validSHA256(file.SHA256) || file.Size < 0 || file.Size > maxBytes {
			return ErrInvalid
		}
		seen[file.Name] = true
		if file.Size > maxMetadataSnapshotBytes-activeBytes {
			return ErrTooLarge
		}
		activeBytes += file.Size
		if file.Name == "accounts.sqlite" {
			hasAccounts = true
		}
		if file.HadOriginal {
			if !validSHA256(file.OriginalSHA256) || file.OriginalSize < 0 || file.OriginalSize > maxBytes {
				return ErrInvalid
			}
			if file.OriginalSize > maxMetadataSnapshotBytes-originalBytes {
				return ErrTooLarge
			}
			originalBytes += file.OriginalSize
		} else if file.OriginalSHA256 != "" || file.OriginalSize != 0 {
			return ErrInvalid
		}
	}
	if !hasAccounts {
		return ErrInvalid
	}
	switch receipt.State {
	case rollbackStateActivated:
		if receipt.RolledBackAt != 0 || receipt.AfterDirectory != "" || len(receipt.AfterFiles) != 0 {
			return ErrInvalid
		}
	case rollbackStateRolledBack:
		if receipt.RolledBackAt <= 0 || receipt.AfterDirectory != rollbackAfterName || len(receipt.AfterFiles) > maxRollbackStateFiles {
			return ErrInvalid
		}
		seenAfter := map[string]bool{}
		var afterBytes int64
		for _, file := range receipt.AfterFiles {
			if !rollbackCurrentName(file.Name) || seenAfter[file.Name] || !validSHA256(file.SHA256) || file.Size < 0 || file.Size > maxBytes {
				return ErrInvalid
			}
			if file.Size > maxMetadataSnapshotBytes-afterBytes {
				return ErrTooLarge
			}
			afterBytes += file.Size
			seenAfter[file.Name] = true
		}
	default:
		return ErrInvalid
	}
	return nil
}

func loadRollbackReceipt(root *os.Root, directory string, byteBudget *int64, allowInterrupted bool) (metadataRollbackReceipt, error) {
	var receipt metadataRollbackReceipt
	if !validActivationName(directory, rollbackPrefix) {
		return receipt, ErrInvalid
	}
	dirInfo, err := root.Lstat(directory)
	if err != nil {
		return receipt, err
	}
	if !dirInfo.IsDir() || dirInfo.Mode()&os.ModeSymlink != 0 || dirInfo.Mode().Perm()&0077 != 0 {
		return receipt, errors.New("rollback_directory_not_private")
	}
	uid, ok := currentUID(dirInfo)
	if !ok || uid != uint32(os.Geteuid()) {
		return receipt, errors.New("rollback_directory_not_owned_by_current_user")
	}
	rollbackRoot, err := root.OpenRoot(directory)
	if err != nil {
		return receipt, err
	}
	defer rollbackRoot.Close()
	info, err := validatePrivateOwnedRegularFile(rollbackRoot, rollbackReceiptName)
	if err != nil {
		return receipt, err
	}
	if info.Size() > 256<<10 {
		return receipt, ErrInvalid
	}
	data, err := rollbackRoot.ReadFile(rollbackReceiptName)
	if err != nil {
		return receipt, err
	}
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&receipt); err != nil {
		return metadataRollbackReceipt{}, ErrInvalid
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return metadataRollbackReceipt{}, ErrInvalid
	}
	if err := validateRollbackReceiptShape(directory, receipt); err != nil {
		return metadataRollbackReceipt{}, err
	}
	for _, file := range receipt.Files {
		if file.HadOriginal {
			if _, err := validateOwnedRegularFile(rollbackRoot, file.Name); err != nil {
				return metadataRollbackReceipt{}, err
			}
			if err := verifyRootFile(rollbackRoot, file.Name, file.OriginalSHA256, file.OriginalSize, byteBudget); err != nil {
				return metadataRollbackReceipt{}, err
			}
		} else if _, err := rollbackRoot.Lstat(file.Name); err == nil {
			return metadataRollbackReceipt{}, errors.New("rollback_unexpected_previous_file")
		} else if !errors.Is(err, os.ErrNotExist) {
			return metadataRollbackReceipt{}, err
		}
	}
	if receipt.State == rollbackStateRolledBack {
		afterInfo, err := rollbackRoot.Lstat(receipt.AfterDirectory)
		if err != nil {
			return metadataRollbackReceipt{}, err
		}
		if !afterInfo.IsDir() || afterInfo.Mode()&os.ModeSymlink != 0 || afterInfo.Mode().Perm()&0077 != 0 {
			return metadataRollbackReceipt{}, errors.New("rollback_after_directory_not_private")
		}
		uid, ok := currentUID(afterInfo)
		if !ok || uid != uint32(os.Geteuid()) {
			return metadataRollbackReceipt{}, errors.New("rollback_after_directory_not_owned_by_current_user")
		}
		after, err := rollbackRoot.OpenRoot(receipt.AfterDirectory)
		if err != nil {
			return metadataRollbackReceipt{}, err
		}
		defer after.Close()
		listed := make(map[string]bool, len(receipt.AfterFiles))
		for _, file := range receipt.AfterFiles {
			listed[file.Name] = true
			if _, err := validateOwnedRegularFile(after, file.Name); err != nil {
				return metadataRollbackReceipt{}, err
			}
			if err := verifyRootFile(after, file.Name, file.SHA256, file.Size, byteBudget); err != nil {
				return metadataRollbackReceipt{}, err
			}
		}
		directory, err := after.Open(".")
		if err != nil {
			return metadataRollbackReceipt{}, err
		}
		entries, readErr := directory.ReadDir(len(listed) + 1)
		closeErr := directory.Close()
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			return metadataRollbackReceipt{}, readErr
		}
		if closeErr != nil {
			return metadataRollbackReceipt{}, closeErr
		}
		for _, entry := range entries {
			if !listed[entry.Name()] {
				return metadataRollbackReceipt{}, errors.New("rollback_after_unlisted_file")
			}
		}
	} else {
		afterInfo, err := root.Lstat(path.Join(directory, rollbackAfterName))
		if err == nil && !allowInterrupted {
			return metadataRollbackReceipt{}, errors.New("rollback_after_exists_without_completion")
		}
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return metadataRollbackReceipt{}, err
		}
		if err == nil && (!afterInfo.IsDir() || afterInfo.Mode()&os.ModeSymlink != 0 || afterInfo.Mode().Perm()&0077 != 0) {
			return metadataRollbackReceipt{}, errors.New("rollback_after_directory_not_private")
		}
		if err == nil {
			uid, ok := currentUID(afterInfo)
			if !ok || uid != uint32(os.Geteuid()) {
				return metadataRollbackReceipt{}, errors.New("rollback_after_directory_not_owned_by_current_user")
			}
		}
	}
	return receipt, nil
}

func receiptReason(err error) string {
	switch {
	case errors.Is(err, os.ErrNotExist):
		return "receipt_missing"
	case errors.Is(err, errVerificationBudget):
		return "verification_budget_exceeded"
	case errors.Is(err, ErrTooLarge):
		return "file_too_large"
	default:
		return "receipt_or_rollback_data_invalid"
	}
}

func readPendingJournal(root *os.Root) (activationPlan, error) {
	return loadActivationPlan(root)
}

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
	in, err := src.Open(srcName)
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
