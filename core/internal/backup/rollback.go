package backup

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path"
	"strings"
	"syscall"
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
	f, err := openCheckedBackupFile(root, name, info)
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
	data, err := readRootFileWithIdentity(rollbackRoot, rollbackReceiptName, 256<<10, info)
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
