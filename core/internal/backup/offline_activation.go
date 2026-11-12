package backup

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"

	_ "github.com/mattn/go-sqlite3"
)

const activationJournalName = ".lightisle-offline-restore.json"
const activationPrefix = ".lightisle-activation-"
const rollbackPrefix = "LightIsle-MetadataRollback-"

type activationFile struct {
	Name           string `json:"name"`
	SHA256         string `json:"sha256"`
	Size           int64  `json:"size"`
	HadOriginal    bool   `json:"hadOriginal"`
	OriginalSHA256 string `json:"originalSha256,omitempty"`
	OriginalSize   int64  `json:"originalSize,omitempty"`
}

type activationPlan struct {
	PreviousTransactionID string                `json:"previousTransactionId,omitempty"`
	Operation             string                `json:"operation,omitempty"`
	TransactionID         string                `json:"transactionId,omitempty"`
	Stage                 string                `json:"stage"`
	Install               string                `json:"install,omitempty"`
	Rollback              string                `json:"rollback"`
	Files                 []activationFile      `json:"files"`
	RollbackFiles         []rollbackJournalFile `json:"rollbackFiles,omitempty"`
}

func saveActivationPlan(root *os.Root, name string, p activationPlan) error {
	raw, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	if len(raw) > maxRecoveryJournalBytes {
		return ErrTooLarge
	}
	f, err := root.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, err = f.Write(raw)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return syncPrivateDir(root)
}

func loadActivationPlan(root *os.Root) (activationPlan, error) {
	var p activationPlan
	data, err := readRootFileBounded(root, activationJournalName, maxRecoveryJournalBytes)
	if err != nil {
		return p, err
	}
	if json.Unmarshal(data, &p) != nil {
		return activationPlan{}, ErrInvalid
	}
	if err := validateLoadedPlanHeader(p); err != nil {
		return activationPlan{}, err
	}
	if err := validateLoadedPlanFiles(p); err != nil {
		return activationPlan{}, err
	}
	if err := validateLoadedPlanRollbackFiles(p); err != nil {
		return activationPlan{}, err
	}
	return p, nil
}

func validateLoadedPlanHeader(p activationPlan) error {
	if (p.PreviousTransactionID != "" && !validTransactionID(p.PreviousTransactionID)) ||
		(p.Operation != "" && p.Operation != "activate" && p.Operation != "rollback") ||
		!validActivationName(p.Rollback, rollbackPrefix) ||
		!validActivationName(p.Stage, "LightIsle-RestoredMetadata-") ||
		len(p.Files) < 1 || len(p.Files) > maxRollbackMetadataEntries {
		return ErrInvalid
	}
	if p.Operation == "" || p.Operation == "activate" {
		if !validActivationName(p.Install, activationPrefix) || len(p.RollbackFiles) != 0 {
			return ErrInvalid
		}
		return nil
	}
	if p.Install != rollbackInstallPrefix+p.TransactionID ||
		!validTransactionID(p.TransactionID) ||
		len(p.RollbackFiles) == 0 ||
		len(p.RollbackFiles) > maxRollbackStateFiles {
		return ErrInvalid
	}
	return nil
}

func validateLoadedPlanFiles(p activationPlan) error {
	var stagedBytes, originalBytes int64
	for _, f := range p.Files {
		invalidOriginal := (f.HadOriginal && ((f.OriginalSHA256 == "" && (p.Operation != "" || f.OriginalSize != 0)) ||
			(f.OriginalSHA256 != "" && (!validSHA256(f.OriginalSHA256) || f.OriginalSize < 0 || f.OriginalSize > maxBytes)))) ||
			(!f.HadOriginal && (f.OriginalSHA256 != "" || f.OriginalSize != 0))
		if !activationMetadataName(f.Name) || !validSHA256(f.SHA256) || f.Size < 0 || f.Size > maxBytes || invalidOriginal {
			return ErrInvalid
		}
		if f.Size > maxMetadataSnapshotBytes-stagedBytes {
			return ErrTooLarge
		}
		stagedBytes += f.Size
		if f.HadOriginal {
			if f.OriginalSize > maxMetadataSnapshotBytes-originalBytes {
				return ErrTooLarge
			}
			originalBytes += f.OriginalSize
		}
	}
	return nil
}

func validateLoadedPlanRollbackFiles(p activationPlan) error {
	seen := make(map[string]bool, len(p.RollbackFiles))
	var rollbackBytes int64
	for _, f := range p.RollbackFiles {
		if !rollbackCurrentName(f.Name) || seen[f.Name] || f.Size < 0 || f.Size > maxBytes ||
			(f.Present && !validSHA256(f.SHA256)) || (!f.Present && (f.SHA256 != "" || f.Size != 0)) {
			return ErrInvalid
		}
		if f.Present {
			if f.Size > maxMetadataSnapshotBytes-rollbackBytes {
				return ErrTooLarge
			}
			rollbackBytes += f.Size
		}
		seen[f.Name] = true
	}
	if p.Operation == "rollback" {
		expected := rollbackNames(p.Files)
		if len(expected) != len(p.RollbackFiles) {
			return ErrInvalid
		}
		for _, name := range expected {
			if !seen[name] {
				return ErrInvalid
			}
		}
	}
	return nil
}

// undoActivation restores all original files *without deleting new data*:
// interrupted replacements are quarantined inside the retained rollback
// directory. The journal is removed only after every original is restored.
func undoActivation(root *os.Root, p activationPlan) error {
	if err := validateUndoActivationPlan(p); err != nil {
		return err
	}
	rollbackRoot, err := openOwnedPrivateSubroot(
		root,
		p.Rollback,
		"recovery_rollback_directory_invalid",
		"recovery_rollback_directory_not_owned_by_current_user",
	)
	if err != nil {
		return err
	}
	rollbackOpen := true
	defer func() {
		if rollbackOpen {
			_ = rollbackRoot.Close()
		}
	}()

	installRoot, err := openVerifiedRecoveryInstallRoot(root, p)
	if err != nil {
		return err
	}
	installOpen := installRoot != nil
	defer func() {
		if installOpen {
			_ = installRoot.Close()
		}
	}()

	expectedOriginal, err := restoreAllInterruptedEntries(root, rollbackRoot, installRoot, p)
	if err != nil {
		return err
	}
	if err := verifyPreActivationStateRestored(root, p.Files, expectedOriginal); err != nil {
		return err
	}
	if err := syncPrivateDir(root); err != nil {
		return err
	}
	if err := syncPrivateDir(rollbackRoot); err != nil {
		return err
	}
	if installOpen {
		if err := installRoot.Close(); err != nil {
			return err
		}
		installOpen = false
	}
	if err := purgeRollbackReceiptAndClose(rollbackRoot, &rollbackOpen); err != nil {
		return err
	}
	if err := cleanupInterruptedInstallAndReceipt(root, p); err != nil {
		return err
	}
	return finalizeMetadataJournalState(root, p.PreviousTransactionID, "", false)
}

func validateUndoActivationPlan(p activationPlan) error {
	if !validActivationName(p.Rollback, rollbackPrefix) ||
		!validActivationName(p.Install, activationPrefix) ||
		len(p.Files) < 1 || len(p.Files) > maxRollbackMetadataEntries {
		return ErrInvalid
	}
	seen := make(map[string]bool, len(p.Files))
	for _, entry := range p.Files {
		if !activationMetadataName(entry.Name) || seen[entry.Name] || !validSHA256(entry.SHA256) || entry.Size < 0 || entry.Size > maxBytes {
			return ErrInvalid
		}
		seen[entry.Name] = true
		if entry.HadOriginal && entry.OriginalSHA256 != "" &&
			(!validSHA256(entry.OriginalSHA256) || entry.OriginalSize < 0 || entry.OriginalSize > maxBytes) {
			return ErrInvalid
		}
	}
	return nil
}

// openVerifiedRecoveryInstallRoot opens p.Install if it still exists and verifies
// that every remaining child is a valid staged file listed in p.Files.
func openVerifiedRecoveryInstallRoot(root *os.Root, p activationPlan) (*os.Root, error) {
	installRoot, err := openOwnedPrivateSubroot(
		root,
		p.Install,
		"recovery_install_directory_invalid",
		"recovery_install_directory_not_owned_by_current_user",
	)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if verifyErr := verifyRecoveryInstallListing(installRoot, p.Files); verifyErr != nil {
		_ = installRoot.Close()
		return nil, verifyErr
	}
	return installRoot, nil
}

func verifyRecoveryInstallListing(installRoot *os.Root, files []activationFile) error {
	listing, err := installRoot.Open(".")
	if err != nil {
		return err
	}
	entries, readErr := listing.ReadDir(len(files) + 1)
	closeErr := listing.Close()
	if readErr != nil && !errors.Is(readErr, io.EOF) {
		return readErr
	}
	if closeErr != nil {
		return closeErr
	}
	if len(entries) > len(files) {
		return errors.New("recovery_install_contains_unlisted_files")
	}
	byName := make(map[string]activationFile, len(files))
	for _, entry := range files {
		byName[entry.Name] = entry
	}
	for _, child := range entries {
		want, found := byName[child.Name()]
		if !found {
			return errors.New("recovery_install_contains_unlisted_files")
		}
		if _, err := validateOwnedRegularFile(installRoot, child.Name()); err != nil {
			return err
		}
		if err := verifyRootFile(installRoot, child.Name(), want.SHA256, want.Size, nil); err != nil {
			return fmt.Errorf("recovery_install_file_invalid: %s: %w", child.Name(), err)
		}
	}
	return nil
}

func restoreAllInterruptedEntries(
	root *os.Root,
	rollbackRoot *os.Root,
	installRoot *os.Root,
	p activationPlan,
) (map[string]fileDigest, error) {
	expectedOriginal := make(map[string]fileDigest, len(p.Files))
	for _, entry := range p.Files {
		if entry.HadOriginal {
			orig, err := restoreOriginalInterruptedEntry(root, rollbackRoot, p.Rollback, entry)
			if err != nil {
				return nil, err
			}
			expectedOriginal[entry.Name] = orig
			continue
		}
		if err := quarantineNewInterruptedEntry(root, rollbackRoot, installRoot, p.Rollback, entry); err != nil {
			return nil, err
		}
	}
	return expectedOriginal, nil
}

func restoreOriginalInterruptedEntry(
	root *os.Root,
	rollbackRoot *os.Root,
	rollbackDir string,
	entry activationFile,
) (fileDigest, error) {
	_, savedErr := rollbackRoot.Lstat(entry.Name)
	if savedErr != nil && !errors.Is(savedErr, os.ErrNotExist) {
		return fileDigest{}, savedErr
	}
	_, currentErr := root.Lstat(entry.Name)
	if currentErr != nil && !errors.Is(currentErr, os.ErrNotExist) {
		return fileDigest{}, currentErr
	}
	quarantineName := ".interrupted-new-" + entry.Name
	_, quarantineErr := rollbackRoot.Lstat(quarantineName)
	if quarantineErr != nil && !errors.Is(quarantineErr, os.ErrNotExist) {
		return fileDigest{}, quarantineErr
	}
	currentExists := currentErr == nil
	quarantineExists := quarantineErr == nil

	original, err := resolveOriginalFileDigest(rollbackRoot, entry, savedErr)
	if err != nil {
		return fileDigest{}, err
	}
	if currentExists {
		currentMatches := false
		if _, err := validateOwnedRegularFile(root, entry.Name); err == nil {
			currentMatches = verifyRootFile(root, entry.Name, original.sha, original.size, nil) == nil
		}
		if !currentMatches {
			if savedErr != nil {
				return fileDigest{}, fmt.Errorf("interrupted_activation_original_missing: %s", entry.Name)
			}
			if quarantineExists {
				return fileDigest{}, fmt.Errorf("interrupted_activation_quarantine_conflict: %s", entry.Name)
			}
			if err := renameAndSyncDirs(root, entry.Name, path.Join(rollbackDir, quarantineName), rollbackRoot, root); err != nil {
				return fileDigest{}, err
			}
			currentExists = false
		}
	}
	if !currentExists {
		if savedErr != nil {
			return fileDigest{}, fmt.Errorf("interrupted_activation_original_missing: %s", entry.Name)
		}
		if err := renameAndSyncDirs(root, path.Join(rollbackDir, entry.Name), entry.Name, root, rollbackRoot); err != nil {
			return fileDigest{}, err
		}
	}
	return original, nil
}

func resolveOriginalFileDigest(
	rollbackRoot *os.Root,
	entry activationFile,
	savedErr error,
) (fileDigest, error) {
	var original fileDigest
	if entry.OriginalSHA256 != "" {
		original = fileDigest{sha: entry.OriginalSHA256, size: entry.OriginalSize}
	} else {
		if savedErr != nil {
			return fileDigest{}, errors.New("interrupted_activation_original_identity_unavailable")
		}
		if _, err := validateOwnedRegularFile(rollbackRoot, entry.Name); err != nil {
			return fileDigest{}, err
		}
		sha, size, err := hashRootFile(rollbackRoot, entry.Name, maxBytes)
		if err != nil {
			return fileDigest{}, err
		}
		original = fileDigest{sha: sha, size: size}
	}
	if savedErr == nil {
		if _, err := validateOwnedRegularFile(rollbackRoot, entry.Name); err != nil {
			return fileDigest{}, err
		}
		if err := verifyRootFile(rollbackRoot, entry.Name, original.sha, original.size, nil); err != nil {
			return fileDigest{}, fmt.Errorf("interrupted_activation_rollback_copy_invalid: %s: %w", entry.Name, err)
		}
	}
	return original, nil
}

func quarantineNewInterruptedEntry(
	root *os.Root,
	rollbackRoot *os.Root,
	installRoot *os.Root,
	rollbackDir string,
	entry activationFile,
) error {
	_, currentErr := root.Lstat(entry.Name)
	if currentErr != nil && !errors.Is(currentErr, os.ErrNotExist) {
		return currentErr
	}
	pendingErr := error(os.ErrNotExist)
	if installRoot != nil {
		_, pendingErr = installRoot.Lstat(entry.Name)
		if pendingErr != nil && !errors.Is(pendingErr, os.ErrNotExist) {
			return pendingErr
		}
	}
	quarantineName := ".interrupted-new-" + entry.Name
	_, quarantineErr := rollbackRoot.Lstat(quarantineName)
	if quarantineErr != nil && !errors.Is(quarantineErr, os.ErrNotExist) {
		return quarantineErr
	}
	currentExists := currentErr == nil
	pendingExists := pendingErr == nil
	quarantineExists := quarantineErr == nil

	if currentExists {
		if pendingExists || quarantineExists {
			return fmt.Errorf("interrupted_activation_new_file_conflict: %s", entry.Name)
		}
		if _, err := validateOwnedRegularFile(root, entry.Name); err != nil {
			return err
		}
		if err := verifyRootFile(root, entry.Name, entry.SHA256, entry.Size, nil); err != nil {
			return fmt.Errorf("interrupted_activation_unexpected_new_file: %s: %w", entry.Name, err)
		}
		if err := renameAndSyncDirs(root, entry.Name, path.Join(rollbackDir, quarantineName), rollbackRoot, root); err != nil {
			return err
		}
		quarantineExists = true
	}
	if pendingExists == quarantineExists {
		return fmt.Errorf("interrupted_activation_new_file_state_unknown: %s", entry.Name)
	}
	if pendingExists {
		if _, err := validateOwnedRegularFile(installRoot, entry.Name); err != nil {
			return err
		}
		if err := verifyRootFile(installRoot, entry.Name, entry.SHA256, entry.Size, nil); err != nil {
			return fmt.Errorf("interrupted_activation_pending_file_invalid: %s: %w", entry.Name, err)
		}
		return nil
	}
	if _, err := validateOwnedRegularFile(rollbackRoot, quarantineName); err != nil {
		return err
	}
	if err := verifyRootFile(rollbackRoot, quarantineName, entry.SHA256, entry.Size, nil); err != nil {
		return fmt.Errorf("interrupted_activation_quarantine_invalid: %s: %w", entry.Name, err)
	}
	return nil
}

func verifyPreActivationStateRestored(
	root *os.Root,
	files []activationFile,
	expectedOriginal map[string]fileDigest,
) error {
	for _, entry := range files {
		if entry.HadOriginal {
			original := expectedOriginal[entry.Name]
			if _, err := validateOwnedRegularFile(root, entry.Name); err != nil {
				return err
			}
			if err := verifyRootFile(root, entry.Name, original.sha, original.size, nil); err != nil {
				return fmt.Errorf("interrupted_activation_original_not_restored: %s: %w", entry.Name, err)
			}
			continue
		}
		if _, err := root.Lstat(entry.Name); err == nil {
			return fmt.Errorf("interrupted_activation_new_file_still_live: %s", entry.Name)
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

func purgeRollbackReceiptAndClose(rollbackRoot *os.Root, openFlag *bool) error {
	if err := rollbackRoot.Remove(rollbackReceiptName); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := syncPrivateDir(rollbackRoot); err != nil {
		return err
	}
	if err := rollbackRoot.Close(); err != nil {
		return err
	}
	*openFlag = false
	return nil
}

func cleanupInterruptedInstallAndReceipt(root *os.Root, p activationPlan) error {
	if err := root.RemoveAll(p.Install); err != nil {
		return err
	}
	if err := syncPrivateDir(root); err != nil {
		return err
	}
	if !validActivationName(p.Rollback, rollbackPrefix) {
		return nil
	}
	rollbackRoot, openErr := root.OpenRoot(p.Rollback)
	if errors.Is(openErr, os.ErrNotExist) {
		return nil
	}
	if openErr != nil {
		return openErr
	}
	if err := rollbackRoot.Remove(rollbackReceiptName); err != nil && !errors.Is(err, os.ErrNotExist) {
		_ = rollbackRoot.Close()
		return err
	}
	if err := syncPrivateDir(rollbackRoot); err != nil {
		_ = rollbackRoot.Close()
		return err
	}
	return rollbackRoot.Close()
}

// RecoverInterruptedActivation runs only while holding the exclusive data
// directory lock. It dispatches activation undo or rollback completion from
// the durable journal. Never invoke it from a Web API or a live application.
func RecoverInterruptedActivation(dataDir string) error {
	lock, err := LockDataDir(dataDir)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := validatePrivateOwnedDir(dataDir); err != nil {
		return err
	}
	root, err := os.OpenRoot(dataDir)
	if err != nil {
		return err
	}
	defer root.Close()
	plan, err := loadActivationPlan(root)
	if errors.Is(err, os.ErrNotExist) {
		if _, markerErr := root.Lstat(revokeRecoverySessionsName); markerErr == nil {
			return FinalizeRecoverySessions(dataDir)
		} else if !errors.Is(markerErr, os.ErrNotExist) {
			return markerErr
		}
		return err
	}
	if err != nil {
		return err
	}
	if plan.Operation == "rollback" {
		err = undoMetadataRollback(root, plan)
	} else {
		err = undoActivation(root, plan)
	}
	if err != nil {
		return err
	}
	return FinalizeRecoverySessions(dataDir)
}

// ActivateStagedMetadata performs an offline journaled replacement of the
// allowlisted application databases/settings. New files are fully staged
// and verified before the first existing file is moved to rollback storage.
// A process crash leaves an on-disk journal and blocks normal Core startup.
func ActivateStagedMetadata(dataDir, stage string) (string, error) {
	return ActivateStagedMetadataWithManifestSHA256(dataDir, stage, "")
}

// ActivateStagedMetadataWithManifestSHA256 optionally binds an owner's
// preview confirmation to the exact staged manifest they reviewed.
func ActivateStagedMetadataWithManifestSHA256(dataDir, stage, expectedManifestSHA256 string) (string, error) {
	if expectedManifestSHA256 != "" && !validSHA256(expectedManifestSHA256) {
		return "", ErrInvalid
	}
	lock, err := LockDataDir(dataDir)
	if err != nil {
		return "", err
	}
	defer lock.Close()

	entries, err := verifyActivationPreconditions(dataDir, stage, expectedManifestSHA256)
	if err != nil {
		return "", err
	}
	root, err := os.OpenRoot(dataDir)
	if err != nil {
		return "", err
	}
	defer root.Close()

	previousTransaction, err := readActiveMetadata(root)
	if err != nil {
		return "", err
	}
	identifier := id()
	p := activationPlan{
		Operation:             "activate",
		TransactionID:         identifier,
		Stage:                 stage,
		Install:               activationPrefix + identifier,
		PreviousTransactionID: previousTransaction,
		Rollback:              rollbackPrefix + identifier,
		Files:                 make([]activationFile, 0, len(entries)),
	}
	if err := root.Mkdir(p.Install, 0700); err != nil {
		return "", err
	}
	stagingComplete := false
	defer func() {
		if !stagingComplete {
			_ = root.RemoveAll(p.Install)
		}
	}()

	installRoot, err := stageActivationInstallFiles(root, stage, entries, &p)
	if err != nil {
		return "", err
	}
	defer installRoot.Close()

	if err := root.Mkdir(p.Rollback, 0700); err != nil {
		return "", err
	}
	rollbackRoot, err := root.OpenRoot(p.Rollback)
	if err != nil {
		return "", err
	}
	defer rollbackRoot.Close()

	if err := saveActivationPlan(root, activationJournalName, p); err != nil {
		return "", err
	}
	stagingComplete = true

	if err := swapStagedMetadataLive(root, installRoot, rollbackRoot, p); err != nil {
		return "", err
	}
	if err := publishActivatedMetadataState(root, p); err != nil {
		return "", err
	}
	if err := FinalizeRecoverySessions(dataDir); err != nil {
		return "", err
	}
	return filepath.Join(dataDir, p.Rollback), nil
}

func verifyActivationPreconditions(
	dataDir string,
	stage string,
	expectedManifestSHA256 string,
) ([]ManifestEntry, error) {
	if err := validatePrivateOwnedDir(dataDir); err != nil {
		return nil, err
	}
	if MetadataActivationPending(dataDir) {
		return nil, errors.New("recover_interrupted_activation_first")
	}
	entries, err := VerifyStagedMetadata(dataDir, stage)
	if err != nil {
		return nil, err
	}
	if expectedManifestSHA256 != "" {
		manifestSHA, err := stagedManifestSHA256(dataDir, stage)
		if err != nil {
			return nil, err
		}
		if manifestSHA != expectedManifestSHA256 {
			return nil, errors.New("staged_metadata_changed_since_preview")
		}
	}
	return entries, nil
}

func stageActivationInstallFiles(
	root *os.Root,
	stage string,
	entries []ManifestEntry,
	p *activationPlan,
) (*os.Root, error) {
	sourceRoot, err := root.OpenRoot(stage)
	if err != nil {
		return nil, err
	}
	defer sourceRoot.Close()

	installRoot, err := root.OpenRoot(p.Install)
	if err != nil {
		return nil, err
	}
	closeOnErr := true
	defer func() {
		if closeOnErr {
			_ = installRoot.Close()
		}
	}()

	var originalBytes int64
	for _, entry := range entries {
		activationEntry, err := inspectLiveAndStageEntry(root, sourceRoot, installRoot, entry, &originalBytes)
		if err != nil {
			return nil, err
		}
		p.Files = append(p.Files, activationEntry)
	}
	if err := sanitizeAndRehashStagedFiles(installRoot, p.Files); err != nil {
		return nil, err
	}
	if err := syncPrivateDir(installRoot); err != nil {
		return nil, err
	}
	if err := syncPrivateDir(root); err != nil {
		return nil, err
	}
	closeOnErr = false
	return installRoot, nil
}

