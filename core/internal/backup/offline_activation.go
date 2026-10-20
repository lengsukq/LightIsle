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

	_ "github.com/mattn/go-sqlite3"
)

const activationJournalName = ".lightisle-offline-restore.json"
const activationPrefix = ".lightisle-activation-"
const rollbackPrefix = "LightIsle-MetadataRollback-"

type activationFile struct {
	Name        string `json:"name"`
	SHA256      string `json:"sha256"`
	Size        int64  `json:"size"`
	HadOriginal bool   `json:"hadOriginal"`
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
	Stage    string           `json:"stage"`
	Install  string           `json:"install"`
	Rollback string           `json:"rollback"`
	Files    []activationFile `json:"files"`
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
	copied, err := io.Copy(h, io.LimitReader(f, size+1))
	if err != nil {
		return err
	}
	if copied != size || hex.EncodeToString(h.Sum(nil)) != hexSHA {
		return errors.New("metadata_checksum_mismatch")
	}
	return nil
}

func checkSQLite(file string, requiredTable string) error {
	uri := (&url.URL{Scheme: "file", Path: file}).String()
	// Use read-only direct SQLite URI. No schema migrations are performed
	// until the normal application starts with the newly activated files.
	db, err := sql.Open("sqlite3", uri+"?mode=ro&_busy_timeout=3000")
	if err != nil {
		return err
	}
	defer db.Close()
	var result string
	if err := db.QueryRow("PRAGMA quick_check").Scan(&result); err != nil {
		return err
	}
	if result != "ok" {
		return fmt.Errorf("sqlite_integrity_failed: %s", result)
	}
	var count int
	if err := db.QueryRow("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", requiredTable).Scan(&count); err != nil {
		return err
	}
	if count != 1 {
		return fmt.Errorf("sqlite_required_table_missing: %s", requiredTable)
	}
	return nil
}

// VerifyStagedMetadata is side-effect free. Stage must be the trusted basename
// of the recovery folder previously created inside this app's private data
// directory. This is intentionally not a public HTTP endpoint.
func VerifyStagedMetadata(dataDir, stage string) ([]File, error) {
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
	raw, err := staged.ReadFile("metadata-manifest.json")
	if err != nil {
		return nil, err
	}
	if len(raw) > 1<<20 {
		return nil, ErrInvalid
	}
	var entries []File
	if err := json.Unmarshal(raw, &entries); err != nil {
		return nil, ErrInvalid
	}
	if len(entries) < 1 || len(entries) > 6 {
		return nil, ErrInvalid
	}
	allowed := map[string]string{"accounts.sqlite": "users", "gallery.sqlite": "assets",
		"cinema.sqlite": "films", "tasks.sqlite": "task_journal",
		"shared-root.json": "", "backup-schedule.json": ""}
	seen := map[string]bool{}
	for _, entry := range entries {
		required, ok := allowed[entry.Path]
		if !ok || seen[entry.Path] || entry.Size < 0 || entry.Size > maxBytes || len(entry.SHA256) != 64 {
			return nil, ErrInvalid
		}
		seen[entry.Path] = true
		if err := verifyDigest(staged, entry.Path, entry.SHA256, entry.Size); err != nil {
			return nil, err
		}
		if required != "" {
			// SQLite verification happens against a private snapshot, and
			// never opens the current production database.
			if err := checkSQLite(filepath.Join(dataDir, stage, entry.Path), required); err != nil {
				return nil, err
			}
		} else {
			raw, err := staged.ReadFile(entry.Path)
			if err != nil {
				return nil, err
			}
			var obj map[string]any
			if err := json.Unmarshal(raw, &obj); err != nil || obj == nil {
				return nil, ErrInvalid
			}
		}
	}
	if !seen["accounts.sqlite"] {
		return nil, ErrInvalid
	}
	return entries, nil
}

func saveActivationPlan(root *os.Root, name string, p activationPlan) error {
	raw, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
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
	data, err := root.ReadFile(activationJournalName)
	if err != nil {
		return p, err
	}
	if len(data) > 1<<20 {
		return p, ErrInvalid
	}
	if json.Unmarshal(data, &p) != nil || !validActivationName(p.Install, activationPrefix) ||
		!validActivationName(p.Rollback, rollbackPrefix) || !validActivationName(p.Stage, "LightIsle-RestoredMetadata-") ||
		len(p.Files) < 1 || len(p.Files) > 6 {
		return activationPlan{}, ErrInvalid
	}
	for _, f := range p.Files {
		if !safeName(f.Name) || strings.Contains(f.Name, "/") || len(f.SHA256) != 64 {
			return activationPlan{}, ErrInvalid
		}
	}
	return p, nil
}

// undoActivation restores all original files *without deleting new data*:
// interrupted replacements are quarantined inside the retained rollback
// directory. The journal is removed only after every original is restored.
func undoActivation(root *os.Root, p activationPlan) error {
	for _, entry := range p.Files {
		saved := path.Join(p.Rollback, entry.Name)
		_, savedErr := root.Lstat(saved)
		_, currentErr := root.Lstat(entry.Name)
		_, pendingErr := root.Lstat(path.Join(p.Install, entry.Name))
		if entry.HadOriginal && savedErr == nil {
			if currentErr == nil {
				quarantine := path.Join(p.Rollback, ".interrupted-new-"+entry.Name)
				if err := root.Rename(entry.Name, quarantine); err != nil {
					return err
				}
			}
			if err := root.Rename(saved, entry.Name); err != nil {
				return err
			}
		} else if !entry.HadOriginal && currentErr == nil && errors.Is(pendingErr, os.ErrNotExist) {
			quarantine := path.Join(p.Rollback, ".interrupted-new-"+entry.Name)
			if err := root.Rename(entry.Name, quarantine); err != nil {
				return err
			}
		}
	}
	if err := syncPrivateDir(root); err != nil {
		return err
	}
	if err := root.Remove(activationJournalName); err != nil {
		return err
	}
	// An interrupted install may have pending files. They are copies from
	// the retained verified recovery folder and are safe to discard here.
	if err := root.RemoveAll(p.Install); err != nil {
		return err
	}
	return syncPrivateDir(root)
}

// RecoverInterruptedActivation runs only while holding the exclusive data
// directory lock. Never invoke it from a Web API or a live application.
func RecoverInterruptedActivation(dataDir string) error {
	lock, err := LockDataDir(dataDir)
	if err != nil {
		return err
	}
	defer lock.Close()
	root, err := os.OpenRoot(dataDir)
	if err != nil {
		return err
	}
	defer root.Close()
	plan, err := loadActivationPlan(root)
	if err != nil {
		return err
	}
	return undoActivation(root, plan)
}

// ActivateStagedMetadata performs an offline journaled replacement of the
// allowlisted application databases/settings. New files are fully staged
// and verified before the first existing file is moved to rollback storage.
// A process crash leaves an on-disk journal and blocks normal Core startup.
func ActivateStagedMetadata(dataDir, stage string) (string, error) {
	lock, err := LockDataDir(dataDir)
	if err != nil {
		return "", err
	}
	defer lock.Close()
	if RecoveryPending(dataDir) {
		return "", errors.New("recover_interrupted_activation_first")
	}
	entries, err := VerifyStagedMetadata(dataDir, stage)
	if err != nil {
		return "", err
	}
	root, err := os.OpenRoot(dataDir)
	if err != nil {
		return "", err
	}
	defer root.Close()
	identifier := id()
	p := activationPlan{Stage: stage, Install: activationPrefix + identifier,
		Rollback: rollbackPrefix + identifier, Files: make([]activationFile, 0, len(entries))}
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
	for _, entry := range entries {
		_, originalErr := root.Lstat(entry.Path)
		if originalErr != nil && !errors.Is(originalErr, os.ErrNotExist) {
			return "", originalErr
		}
		if originalErr == nil {
			if _, err := regularFile(root, entry.Path); err != nil {
				return "", err
			}
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
			Size: entry.Size, HadOriginal: originalErr == nil})
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
	if err := syncPrivateDir(installRoot); err != nil {
		return "", err
	}
	if err := syncPrivateDir(root); err != nil {
		return "", err
	}
	if err := root.Mkdir(p.Rollback, 0700); err != nil {
		return "", err
	}
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
		}
		if err := root.Rename(path.Join(p.Install, entry.Name), entry.Name); err != nil {
			_ = undoActivation(root, p)
			return "", err
		}
		if err := syncPrivateDir(root); err != nil {
			_ = undoActivation(root, p)
			return "", err
		}
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
	return filepath.Join(dataDir, p.Rollback), nil
}
