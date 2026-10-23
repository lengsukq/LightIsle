package backup

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

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

func syncPrivateDir(root *os.Root) error {
	f, err := root.Open(".")
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
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

func validActivationName(name, prefix string) bool {
	return strings.HasPrefix(name, prefix) && len(name) > len(prefix) && path.Base(name) == name &&
		!strings.ContainsAny(name, "/\\\x00")
}

func regularFile(root *os.Root, name string) (os.FileInfo, error) {
	info, err := root.Lstat(name)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, ErrInvalid
	}
	return info, nil
}

func verifyDigest(root *os.Root, name, hexSHA string, size int64) error {
	return verifyDigestContext(context.Background(), root, name, hexSHA, size)
}

func verifyDigestContext(ctx context.Context, root *os.Root, name, hexSHA string, size int64) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	info, err := regularFile(root, name)
	if err != nil {
		return err
	}
	if info.Size() != size {
		return errors.New("metadata_size_mismatch")
	}
	f, err := root.Open(name)
	if err != nil {
		return err
	}
	defer f.Close()
	h := sha256.New()
	copied, err := io.Copy(h, io.LimitReader(cancellationReader{ctx: ctx, source: f}, size+1))
	if err != nil {
		return err
	}
	if copied != size || hex.EncodeToString(h.Sum(nil)) != hexSHA {
		return errors.New("metadata_checksum_mismatch")
	}
	return nil
}

func checkSQLite(file string, requiredTable string) error {
	return checkSQLiteContext(context.Background(), file, requiredTable)
}

func checkSQLiteContext(ctx context.Context, file string, requiredTable string) error {
	uri := (&url.URL{Scheme: "file", Path: file}).String()
	// Use read-only direct SQLite URI. No schema migrations are performed
	// until the normal application starts with the newly activated files.
	db, err := sql.Open("sqlite3", uri+"?mode=ro&_query_only=1&_busy_timeout=500")
	if err != nil {
		return err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	var result string
	if err := db.QueryRowContext(ctx, "PRAGMA quick_check").Scan(&result); err != nil {
		return err
	}
	if result != "ok" {
		return fmt.Errorf("sqlite_integrity_failed: %s", result)
	}
	if requiredTable != "" {
		var count int
		if err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", requiredTable).Scan(&count); err != nil {
			return err
		}
		if count != 1 {
			return fmt.Errorf("sqlite_required_table_missing: %s", requiredTable)
		}
	}
	return nil
}

// VerifyStagedMetadata is side-effect free. Stage must be the trusted basename
// of the recovery folder previously created inside this app's private data
// directory. This is intentionally not a public HTTP endpoint.
func VerifyStagedMetadata(dataDir, stage string) ([]File, error) {
	return VerifyStagedMetadataContext(context.Background(), dataDir, stage)
}

// VerifyStagedMetadataContext is the cancellable form used by owner-facing
// preview. It hashes each staged object and checks every staged SQLite file
// without opening the current database or changing either side.
func VerifyStagedMetadataContext(ctx context.Context, dataDir, stage string) ([]File, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if !validActivationName(stage, "LightIsle-RestoredMetadata-") {
		return nil, ErrInvalid
	}
	root, err := os.OpenRoot(dataDir)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	info, err := root.Lstat(stage)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, ErrInvalid
	}
	staged, err := root.OpenRoot(stage)
	if err != nil {
		return nil, err
	}
	defer staged.Close()
	raw, err := readRootFileBounded(staged, "metadata-manifest.json", maxMetadataManifestBytes)
	if err != nil {
		return nil, err
	}
	var entries []File
	if err := json.Unmarshal(raw, &entries); err != nil {
		return nil, ErrInvalid
	}
	rootIDs, registryPresent, err := readRegisteredRootIDs(staged)
	if err != nil {
		return nil, err
	}
	if err := validateMetadataCatalog(entries, rootIDs); err != nil {
		return nil, err
	}
	registered := registeredIDSet(rootIDs)
	seen := map[string]bool{}
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		_, ok := metadataTableForName(entry.Path, registered)
		if !ok || seen[entry.Path] {
			return nil, ErrInvalid
		}
		seen[entry.Path] = true
		if err := verifyDigestContext(ctx, staged, entry.Path, entry.SHA256, entry.Size); err != nil {
			return nil, err
		}
		if strings.HasSuffix(entry.Path, ".sqlite") {
			// Older valid stages can predate a table or migration. Integrity is
			// required here; the preview reports missing count tables as unknown.
			if err := checkSQLiteContext(ctx, filepath.Join(dataDir, stage, entry.Path), ""); err != nil {
				return nil, err
			}
		} else {
			raw, err := readRootFileBounded(staged, entry.Path, 4<<20)
			if err != nil {
				return nil, err
			}
			var obj map[string]any
			if err := json.Unmarshal(raw, &obj); err != nil || obj == nil {
				return nil, ErrInvalid
			}
		}
	}
	if registryPresent && !seen["shared-roots.json"] {
		return nil, ErrInvalid
	}
	return entries, nil
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
	if json.Unmarshal(data, &p) != nil ||
		(p.PreviousTransactionID != "" && !validTransactionID(p.PreviousTransactionID)) ||
		(p.Operation != "" && p.Operation != "activate" && p.Operation != "rollback") ||
		!validActivationName(p.Rollback, rollbackPrefix) || !validActivationName(p.Stage, "LightIsle-RestoredMetadata-") ||
		len(p.Files) < 1 || len(p.Files) > maxRollbackMetadataEntries {
		return activationPlan{}, ErrInvalid
	}
	if p.Operation == "" || p.Operation == "activate" {
		if !validActivationName(p.Install, activationPrefix) || len(p.RollbackFiles) != 0 {
			return activationPlan{}, ErrInvalid
		}
	} else if p.Install != rollbackInstallPrefix+p.TransactionID || !validTransactionID(p.TransactionID) || len(p.RollbackFiles) == 0 || len(p.RollbackFiles) > maxRollbackStateFiles {
		return activationPlan{}, ErrInvalid
	}
	var stagedBytes, originalBytes int64
	for _, f := range p.Files {
		if !activationMetadataName(f.Name) || !validSHA256(f.SHA256) || f.Size < 0 || f.Size > maxBytes ||
			(f.HadOriginal && ((f.OriginalSHA256 == "" && (p.Operation != "" || f.OriginalSize != 0)) ||
				(f.OriginalSHA256 != "" && (!validSHA256(f.OriginalSHA256) || f.OriginalSize < 0 || f.OriginalSize > maxBytes)))) ||
			(!f.HadOriginal && (f.OriginalSHA256 != "" || f.OriginalSize != 0)) {
			return activationPlan{}, ErrInvalid
		}
		if f.Size > maxMetadataSnapshotBytes-stagedBytes {
			return activationPlan{}, ErrTooLarge
		}
		stagedBytes += f.Size
		if f.HadOriginal {
			if f.OriginalSize > maxMetadataSnapshotBytes-originalBytes {
				return activationPlan{}, ErrTooLarge
			}
			originalBytes += f.OriginalSize
		}
	}
	seen := map[string]bool{}
	var rollbackBytes int64
	for _, f := range p.RollbackFiles {
		if !rollbackCurrentName(f.Name) || seen[f.Name] || f.Size < 0 || f.Size > maxBytes ||
			(f.Present && !validSHA256(f.SHA256)) || (!f.Present && (f.SHA256 != "" || f.Size != 0)) {
			return activationPlan{}, ErrInvalid
		}
		if f.Present {
			if f.Size > maxMetadataSnapshotBytes-rollbackBytes {
				return activationPlan{}, ErrTooLarge
			}
			rollbackBytes += f.Size
		}
		seen[f.Name] = true
	}
	if p.Operation == "rollback" {
		expected := rollbackNames(p.Files)
		if len(expected) != len(p.RollbackFiles) {
			return activationPlan{}, ErrInvalid
		}
		for _, name := range expected {
			if !seen[name] {
				return activationPlan{}, ErrInvalid
			}
		}
	}
	return p, nil
}

// undoActivation restores all original files *without deleting new data*:
// interrupted replacements are quarantined inside the retained rollback
// directory. The journal is removed only after every original is restored.
func undoActivation(root *os.Root, p activationPlan) error {
	if !validActivationName(p.Rollback, rollbackPrefix) || !validActivationName(p.Install, activationPrefix) ||
		len(p.Files) < 1 || len(p.Files) > maxRollbackMetadataEntries {
		return ErrInvalid
	}
	rollbackInfo, err := root.Lstat(p.Rollback)
	if err != nil {
		return err
	}
	if !rollbackInfo.IsDir() || rollbackInfo.Mode()&os.ModeSymlink != 0 || rollbackInfo.Mode().Perm()&0077 != 0 {
		return errors.New("recovery_rollback_directory_invalid")
	}
	uid, ok := currentUID(rollbackInfo)
	if !ok || uid != uint32(os.Geteuid()) {
		return errors.New("recovery_rollback_directory_not_owned_by_current_user")
	}
	rollbackRoot, err := root.OpenRoot(p.Rollback)
	if err != nil {
		return err
	}
	rollbackOpen := true
	defer func() {
		if rollbackOpen {
			_ = rollbackRoot.Close()
		}
	}()

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

	// A missing install directory is possible after an earlier recovery removed
	// it but crashed before the journal deletion became durable. If it remains,
	// every child must still be one of the verified staged files; do not erase
	// unrelated files during cleanup.
	var installRoot *os.Root
	installInfo, installErr := root.Lstat(p.Install)
	if installErr == nil {
		if !installInfo.IsDir() || installInfo.Mode()&os.ModeSymlink != 0 || installInfo.Mode().Perm()&0077 != 0 {
			return errors.New("recovery_install_directory_invalid")
		}
		uid, ok := currentUID(installInfo)
		if !ok || uid != uint32(os.Geteuid()) {
			return errors.New("recovery_install_directory_not_owned_by_current_user")
		}
		installRoot, err = root.OpenRoot(p.Install)
		if err != nil {
			return err
		}
	} else if !errors.Is(installErr, os.ErrNotExist) {
		return installErr
	}
	installOpen := installRoot != nil
	if installOpen {
		defer func() {
			if installOpen {
				_ = installRoot.Close()
			}
		}()
		listing, err := installRoot.Open(".")
		if err != nil {
			return err
		}
		entries, readErr := listing.ReadDir(len(p.Files) + 1)
		closeErr := listing.Close()
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			return readErr
		}
		if closeErr != nil {
			return closeErr
		}
		if len(entries) > len(p.Files) {
			return errors.New("recovery_install_contains_unlisted_files")
		}
		byName := make(map[string]activationFile, len(p.Files))
		for _, entry := range p.Files {
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
	}

	// Legacy activation journals did not persist the old file digest. If the
	// rollback copy is present, capture and verify it for this recovery attempt.
	// If it is already gone, a legacy journal cannot prove that a live file is
	// the old version, so keep the journal for manual repair.
	type fileDigest struct {
		sha  string
		size int64
	}
	expectedOriginal := make(map[string]fileDigest, len(p.Files))
	for _, entry := range p.Files {
		savedErr := error(nil)
		if _, savedErr = rollbackRoot.Lstat(entry.Name); savedErr != nil && !errors.Is(savedErr, os.ErrNotExist) {
			return savedErr
		}
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

		if entry.HadOriginal {
			var original fileDigest
			if entry.OriginalSHA256 != "" {
				original = fileDigest{sha: entry.OriginalSHA256, size: entry.OriginalSize}
			} else {
				if savedErr != nil {
					return errors.New("interrupted_activation_original_identity_unavailable")
				}
				if _, err := validateOwnedRegularFile(rollbackRoot, entry.Name); err != nil {
					return err
				}
				sha, size, err := hashRootFile(rollbackRoot, entry.Name, maxBytes)
				if err != nil {
					return err
				}
				original = fileDigest{sha: sha, size: size}
			}
			if savedErr == nil {
				if _, err := validateOwnedRegularFile(rollbackRoot, entry.Name); err != nil {
					return err
				}
				if err := verifyRootFile(rollbackRoot, entry.Name, original.sha, original.size, nil); err != nil {
					return fmt.Errorf("interrupted_activation_rollback_copy_invalid: %s: %w", entry.Name, err)
				}
			}
			if currentExists {
				currentMatches := false
				if _, err := validateOwnedRegularFile(root, entry.Name); err == nil {
					currentMatches = verifyRootFile(root, entry.Name, original.sha, original.size, nil) == nil
				}
				if !currentMatches {
					if savedErr != nil {
						return fmt.Errorf("interrupted_activation_original_missing: %s", entry.Name)
					}
					if quarantineExists {
						return fmt.Errorf("interrupted_activation_quarantine_conflict: %s", entry.Name)
					}
					if err := root.Rename(entry.Name, path.Join(p.Rollback, quarantineName)); err != nil {
						return err
					}
					// Persist the destination before the source removal so a crash
					// cannot lose the displaced file between the two directories.
					if err := syncPrivateDir(rollbackRoot); err != nil {
						return err
					}
					if err := syncPrivateDir(root); err != nil {
						return err
					}
					currentExists = false
				}
			}
			if !currentExists {
				if savedErr != nil {
					return fmt.Errorf("interrupted_activation_original_missing: %s", entry.Name)
				}
				if err := root.Rename(path.Join(p.Rollback, entry.Name), entry.Name); err != nil {
					return err
				}
				// Persist the restored file before persisting removal of its
				// rollback copy. A crash may leave a duplicate, never lose both.
				if err := syncPrivateDir(root); err != nil {
					return err
				}
				if err := syncPrivateDir(rollbackRoot); err != nil {
					return err
				}
			}
			expectedOriginal[entry.Name] = original
		} else {
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
				if err := root.Rename(entry.Name, path.Join(p.Rollback, quarantineName)); err != nil {
					return err
				}
				if err := syncPrivateDir(rollbackRoot); err != nil {
					return err
				}
				if err := syncPrivateDir(root); err != nil {
					return err
				}
				quarantineExists = true
				currentExists = false
			}
			if !currentExists {
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
				} else {
					if _, err := validateOwnedRegularFile(rollbackRoot, quarantineName); err != nil {
						return err
					}
					if err := verifyRootFile(rollbackRoot, quarantineName, entry.SHA256, entry.Size, nil); err != nil {
						return fmt.Errorf("interrupted_activation_quarantine_invalid: %s: %w", entry.Name, err)
					}
				}
			}
		}
	}

	// Verify the complete pre-activation state before cleaning any durable
	// recovery evidence. Missing rollback data or unknown new files must leave
	// the journal in place so normal Core startup remains blocked.
	for _, entry := range p.Files {
		if entry.HadOriginal {
			original := expectedOriginal[entry.Name]
			if _, err := validateOwnedRegularFile(root, entry.Name); err != nil {
				return err
			}
			if err := verifyRootFile(root, entry.Name, original.sha, original.size, nil); err != nil {
				return fmt.Errorf("interrupted_activation_original_not_restored: %s: %w", entry.Name, err)
			}
		} else if _, err := root.Lstat(entry.Name); err == nil {
			return fmt.Errorf("interrupted_activation_new_file_still_live: %s", entry.Name)
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
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
	if err := rollbackRoot.Remove(rollbackReceiptName); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := syncPrivateDir(rollbackRoot); err != nil {
		return err
	}
	if err := rollbackRoot.Close(); err != nil {
		return err
	}
	rollbackOpen = false
	if err := root.RemoveAll(p.Install); err != nil {
		return err
	}
	if err := syncPrivateDir(root); err != nil {
		return err
	}
	// A receipt is published immediately before the activation journal is
	// removed. If the journal remains, startup must still treat this as an
	// interrupted activation and undo it; do not leave a receipt that makes the
	// reverted transaction appear eligible for a later manual rollback.
	if validActivationName(p.Rollback, rollbackPrefix) {
		rollbackRoot, openErr := root.OpenRoot(p.Rollback)
		if openErr == nil {
			if err := rollbackRoot.Remove(rollbackReceiptName); err != nil && !errors.Is(err, os.ErrNotExist) {
				rollbackRoot.Close()
				return err
			}
			if err := syncPrivateDir(rollbackRoot); err != nil {
				rollbackRoot.Close()
				return err
			}
			if err := rollbackRoot.Close(); err != nil {
				return err
			}
		} else if !errors.Is(openErr, os.ErrNotExist) {
			return openErr
		}
	}
	if err := writeActiveMetadata(root, p.PreviousTransactionID); err != nil {
		return err
	}
	if err := markRecoverySessionRevocation(root); err != nil {
		return err
	}
	if err := root.Remove(activationJournalName); err != nil {
		return err
	}
	return syncPrivateDir(root)
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
	if err := validatePrivateOwnedDir(dataDir); err != nil {
		return "", err
	}
	if MetadataActivationPending(dataDir) {
		return "", errors.New("recover_interrupted_activation_first")
	}
	entries, err := VerifyStagedMetadata(dataDir, stage)
	if err != nil {
		return "", err
	}
	if expectedManifestSHA256 != "" {
		manifestSHA, err := stagedManifestSHA256(dataDir, stage)
		if err != nil {
			return "", err
		}
		if manifestSHA != expectedManifestSHA256 {
			return "", errors.New("staged_metadata_changed_since_preview")
		}
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
	p := activationPlan{Operation: "activate", TransactionID: identifier, Stage: stage, Install: activationPrefix + identifier,
		PreviousTransactionID: previousTransaction, Rollback: rollbackPrefix + identifier, Files: make([]activationFile, 0, len(entries))}
	if err := root.Mkdir(p.Install, 0700); err != nil {
		return "", err
	}
	// Safe until journal creation: no currently active file has been touched.
	stagingComplete := false
	defer func() {
		if !stagingComplete {
			_ = root.RemoveAll(p.Install)
		}
	}()
	sourceRoot, err := root.OpenRoot(stage)
	if err != nil {
		return "", err
	}
	defer sourceRoot.Close()
	installRoot, err := root.OpenRoot(p.Install)
	if err != nil {
		return "", err
	}
	defer installRoot.Close()
	var originalBytes int64
	for _, entry := range entries {
		_, originalErr := root.Lstat(entry.Path)
		if originalErr != nil && !errors.Is(originalErr, os.ErrNotExist) {
			return "", originalErr
		}
		var originalSHA string
		var originalSize int64
		if originalErr == nil {
			if _, err := regularFile(root, entry.Path); err != nil {
				return "", err
			}
			originalSHA, originalSize, err = hashRootFile(root, entry.Path, maxBytes)
			if err != nil {
				return "", err
			}
			if originalSize > maxMetadataSnapshotBytes-originalBytes {
				return "", ErrTooLarge
			}
			originalBytes += originalSize
		}
		if strings.HasSuffix(entry.Path, ".sqlite") {
			// Old WAL and SHM files belong to the previous database inode,
			// not the replacement snapshot. Never attach a new database to
			// obsolete sidecars left by an unclean previous shutdown.
			for _, suffix := range []string{"-wal", "-shm"} {
				if _, e := root.Lstat(entry.Path + suffix); e == nil {
					return "", errors.New("offline_activation_requires_clean_sqlite_shutdown")
				} else if !errors.Is(e, os.ErrNotExist) {
					return "", e
				}
			}
		}
		p.Files = append(p.Files, activationFile{Name: entry.Path, SHA256: entry.SHA256,
			Size: entry.Size, HadOriginal: originalErr == nil, OriginalSHA256: originalSHA,
			OriginalSize: originalSize})
		src, err := sourceRoot.Open(entry.Path)
		if err != nil {
			return "", err
		}
		dst, err := installRoot.OpenFile(entry.Path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			src.Close()
			return "", err
		}
		sha, copyErr := boundedCopy(context.Background(), dst, src, entry.Size)
		closeErr := dst.Close()
		src.Close()
		if copyErr != nil {
			return "", copyErr
		}
		if closeErr != nil {
			return "", closeErr
		}
		if sha != entry.SHA256 {
			return "", errors.New("metadata_checksum_mismatch")
		}
	}
	for _, entry := range p.Files {
		if entry.Name == "accounts.sqlite" {
			if err := clearTransientCapabilities(context.Background(), filepath.Join(installRoot.Name(), entry.Name)); err != nil {
				return "", err
			}
			break
		}
	}
	var activeMetadataBytes int64
	for i := range p.Files {
		if p.Files[i].Name == "accounts.sqlite" {
			sha, size, err := hashRootFile(installRoot, p.Files[i].Name, maxBytes)
			if err != nil {
				return "", err
			}
			p.Files[i].SHA256, p.Files[i].Size = sha, size
		}
		if p.Files[i].Size > maxMetadataSnapshotBytes-activeMetadataBytes {
			return "", ErrTooLarge
		}
		activeMetadataBytes += p.Files[i].Size
	}
	if err := syncPrivateDir(installRoot); err != nil {
		return "", err
	}
	if err := syncPrivateDir(root); err != nil {
		return "", err
	}
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
	// Any error below is followed by a conservative attempt to restore each
	// original. If rollback itself fails, keep the journal: Core will refuse
	// to start and require a deliberate operator repair.
	for _, entry := range p.Files {
		if entry.HadOriginal {
			if err := root.Rename(entry.Name, path.Join(p.Rollback, entry.Name)); err != nil {
				_ = undoActivation(root, p)
				return "", err
			}
			// Persist the rollback destination before persisting removal of the
			// live name. A crash may leave both links, never lose the only copy.
			if err := syncPrivateDir(rollbackRoot); err != nil {
				_ = undoActivation(root, p)
				return "", err
			}
			if err := syncPrivateDir(root); err != nil {
				_ = undoActivation(root, p)
				return "", err
			}
		}
		if err := root.Rename(path.Join(p.Install, entry.Name), entry.Name); err != nil {
			_ = undoActivation(root, p)
			return "", err
		}
		if err := syncPrivateDir(root); err != nil {
			_ = undoActivation(root, p)
			return "", err
		}
		if err := syncPrivateDir(installRoot); err != nil {
			_ = undoActivation(root, p)
			return "", err
		}
	}
	receipt := metadataRollbackReceipt{Version: 1, TransactionID: identifier, Stage: stage,
		PreviousTransactionID: previousTransaction, ActivatedAt: time.Now().UTC().Unix(), State: rollbackStateActivated, Files: append([]activationFile(nil), p.Files...)}
	if err := writeRollbackReceipt(root, p.Rollback, receipt); err != nil {
		return "", err
	}
	if err := writeActiveMetadata(root, identifier); err != nil {
		return "", err
	}
	if err := markRecoverySessionRevocation(root); err != nil {
		return "", err
	}
	if err := root.Remove(activationJournalName); err != nil {
		return "", err
	}
	if err := root.RemoveAll(p.Install); err != nil {
		return "", err
	}
	if err := syncPrivateDir(root); err != nil {
		return "", err
	}
	if err := FinalizeRecoverySessions(dataDir); err != nil {
		return "", err
	}
	return filepath.Join(dataDir, p.Rollback), nil
}
