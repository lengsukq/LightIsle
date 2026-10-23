package backup

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func makeActivationFixture(t *testing.T) (string, string) {
	t.Helper()
	dataDir := t.TempDir()
	current, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if err = current.Setup("original", "original-password-123"); err != nil {
		t.Fatal(err)
	}
	current.Close()
	stageName := "LightIsle-RestoredMetadata-fixture"
	stage := filepath.Join(dataDir, stageName)
	if err := os.Mkdir(stage, 0700); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(t.TempDir(), "accounts.sqlite")
	desired, err := auth.Open(other)
	if err != nil {
		t.Fatal(err)
	}
	if err = desired.Setup("replacement", "replacement-password-123"); err != nil {
		t.Fatal(err)
	}
	desired.Close()
	data, err := os.ReadFile(other)
	if err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(stage, "accounts.sqlite")
	if err = os.WriteFile(target, data, 0600); err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(data)
	manifest, err := json.Marshal([]File{{Path: "accounts.sqlite", Size: int64(len(data)), SHA256: hex.EncodeToString(hash[:])}})
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(stage, "metadata-manifest.json"), manifest, 0600); err != nil {
		t.Fatal(err)
	}
	return dataDir, stageName
}

func TestOfflineActivationRejectsLeftoverOldSQLiteWAL(t *testing.T) {
	dir, stage := makeActivationFixture(t)
	old, err := os.ReadFile(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	wal := filepath.Join(dir, "accounts.sqlite-wal")
	if err := os.WriteFile(wal, []byte("old uncheckpointed sqlite WAL"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := ActivateStagedMetadata(dir, stage); err == nil {
		t.Fatal("activation reattached restored database to previous WAL")
	}
	current, err := os.ReadFile(filepath.Join(dir, "accounts.sqlite"))
	if err != nil || string(current) != string(old) {
		t.Fatalf("rejected stale WAL activation corrupted data: %v", err)
	}
	if RecoveryPending(dir) {
		t.Fatal("failed WAL preflight left recovery journal")
	}
}

func TestOfflineActivationVerifiesBeforeReplacingAndRetainsRollback(t *testing.T) {
	dir, stage := makeActivationFixture(t)
	locked, err := LockDataDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ActivateStagedMetadata(dir, stage); !errors.Is(err, ErrAppRunning) {
		t.Fatalf("live Core lock bypassed: %v", err)
	}
	locked.Close()
	files, err := VerifyStagedMetadata(dir, stage)
	if err != nil || len(files) != 1 {
		t.Fatalf("snapshot preflight: %+v %v", files, err)
	}
	rollback, err := ActivateStagedMetadata(dir, stage)
	if err != nil {
		t.Fatal(err)
	}
	if RecoveryPending(dir) {
		t.Fatal("journal not cleared after completed activation")
	}
	restored, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	configured, err := restored.FirstAdminUsername()
	restored.Close()
	if err != nil || configured != "replacement" {
		t.Fatalf("failed to activate account: %q %v", configured, err)
	}
	old, err := auth.Open(filepath.Join(rollback, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	previous, err := old.FirstAdminUsername()
	old.Close()
	if err != nil || previous != "original" {
		t.Fatalf("original not preserved: %q %v", previous, err)
	}
}

func TestOfflineActivationAndRollbackCoverRegisteredRootMetadata(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	rootID := "0123456789abcdef0123456789abcdef"
	databaseName := rootMetadataName("gallery", rootID)
	registry := []byte(`{"version":1,"roots":[{"rootID":"` + rootID + `"}]}`)
	if err := os.WriteFile(filepath.Join(dir, "shared-roots.json"), registry, 0600); err != nil {
		t.Fatal(err)
	}
	writeMetadataSQLite(t, filepath.Join(dir, "accounts.sqlite"),
		`CREATE TABLE users(id INTEGER PRIMARY KEY,username TEXT)`,
		`INSERT INTO users VALUES(1,'previous')`)
	writeMetadataSQLite(t, filepath.Join(dir, databaseName),
		`CREATE TABLE assets(id INTEGER PRIMARY KEY,label TEXT)`,
		`INSERT INTO assets VALUES(1,'previous-root-library')`)
	previous, err := os.ReadFile(filepath.Join(dir, databaseName))
	if err != nil {
		t.Fatal(err)
	}
	stageName := "LightIsle-RestoredMetadata-root-databases"
	stage := filepath.Join(dir, stageName)
	if err := os.Mkdir(stage, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, "shared-roots.json"), registry, 0600); err != nil {
		t.Fatal(err)
	}
	writeMetadataSQLite(t, filepath.Join(stage, "accounts.sqlite"),
		`CREATE TABLE users(id INTEGER PRIMARY KEY,username TEXT)`,
		`INSERT INTO users VALUES(1,'replacement')`)
	writeMetadataSQLite(t, filepath.Join(stage, databaseName),
		`CREATE TABLE assets(id INTEGER PRIMARY KEY,label TEXT)`,
		`INSERT INTO assets VALUES(1,'restored-root-library')`)
	staged, err := os.ReadFile(filepath.Join(stage, databaseName))
	if err != nil {
		t.Fatal(err)
	}
	entries := make([]File, 0, 3)
	for _, name := range []string{"accounts.sqlite", "shared-roots.json", databaseName} {
		data, err := os.ReadFile(filepath.Join(stage, name))
		if err != nil {
			t.Fatal(err)
		}
		hash := sha256.Sum256(data)
		entries = append(entries, File{Path: name, Size: int64(len(data)), SHA256: hex.EncodeToString(hash[:])})
	}
	manifest, err := json.Marshal(entries)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, "metadata-manifest.json"), manifest, 0600); err != nil {
		t.Fatal(err)
	}
	stageRoot, err := os.OpenRoot(stage)
	if err != nil {
		t.Fatal(err)
	}
	stageIDs, present, err := readRegisteredRootIDs(stageRoot)
	if err != nil || !present || len(stageIDs) != 1 || stageIDs[0] != rootID {
		stageRoot.Close()
		t.Fatalf("stage registry parse failed: ids=%v present=%v err=%v", stageIDs, present, err)
	}
	if err := validateMetadataCatalog(entries, stageIDs); err != nil {
		stageRoot.Close()
		t.Fatalf("stage catalog validation failed: %v", err)
	}
	if err := stageRoot.Close(); err != nil {
		t.Fatal(err)
	}
	if verified, err := VerifyStagedMetadata(dir, stageName); err != nil || len(verified) != 3 {
		t.Fatalf("registered-root stage verify failed: files=%+v err=%v", verified, err)
	}

	rollbackDir, err := ActivateStagedMetadata(dir, stageName)
	if err != nil {
		t.Fatal(err)
	}
	active, err := os.ReadFile(filepath.Join(dir, databaseName))
	if err != nil || string(active) != string(staged) {
		t.Fatalf("registered root database not activated: %v", err)
	}
	transactionID := strings.TrimPrefix(filepath.Base(rollbackDir), rollbackPrefix)
	if _, err := RollbackMetadata(dir, transactionID); err != nil {
		t.Fatal(err)
	}
	rolledBack, err := os.ReadFile(filepath.Join(dir, databaseName))
	if err != nil || string(rolledBack) != string(previous) {
		t.Fatalf("registered root database not restored by rollback: %v", err)
	}
	restoredRegistry, err := os.ReadFile(filepath.Join(dir, "shared-roots.json"))
	if err != nil || string(restoredRegistry) != string(registry) {
		t.Fatalf("registered root registry not restored by rollback: %v", err)
	}
}

func TestOfflineRecoveryUndoInterruptedActivation(t *testing.T) {
	dir, stage := makeActivationFixture(t)
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	p := activationPlan{
		Stage: stage, Install: ".lightisle-activation-interrupted",
		Rollback: "LightIsle-MetadataRollback-interrupted",
		Files:    []activationFile{{Name: "accounts.sqlite", SHA256: strings.Repeat("0", 64), HadOriginal: true}},
	}
	if err = root.Mkdir(p.Install, 0700); err != nil {
		t.Fatal(err)
	}
	if err = root.Mkdir(p.Rollback, 0700); err != nil {
		t.Fatal(err)
	}
	if err = saveActivationPlan(root, activationJournalName, p); err != nil {
		t.Fatal(err)
	}
	if err = root.Rename("accounts.sqlite", filepath.Join(p.Rollback, "accounts.sqlite")); err != nil {
		t.Fatal(err)
	}
	// Crash after old DB moved out of the data directory but before a new
	// DB could be activated. Normal Core startup must block.
	if !RecoveryPending(dir) {
		t.Fatal("interrupted recovery not detected")
	}
	if err = root.Close(); err != nil {
		t.Fatal(err)
	}
	if err = RecoverInterruptedActivation(dir); err != nil {
		t.Fatal(err)
	}
	if RecoveryPending(dir) {
		t.Fatal("journal retained after full rollback")
	}
	store, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	got, err := store.FirstAdminUsername()
	store.Close()
	if err != nil || got != "original" {
		t.Fatalf("original admin lost on rollback: %q %v", got, err)
	}
	if err = RecoverInterruptedActivation(dir); !os.IsNotExist(err) {
		t.Fatalf("unexpected second rollback: %v", err)
	}
}

func TestInterruptedActivationMissingRollbackCopyKeepsJournal(t *testing.T) {
	dir, stage := makeActivationFixture(t)
	oldBytes, err := os.ReadFile(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	newBytes, err := os.ReadFile(filepath.Join(dir, stage, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	oldHash := sha256.Sum256(oldBytes)
	newHash := sha256.Sum256(newBytes)
	entry := activationFile{Name: "accounts.sqlite", SHA256: hex.EncodeToString(newHash[:]), Size: int64(len(newBytes)),
		HadOriginal: true, OriginalSHA256: hex.EncodeToString(oldHash[:]), OriginalSize: int64(len(oldBytes))}
	root, plan := makeInterruptedActivationJournal(t, dir, stage, entry, newBytes)
	if err := root.Rename("accounts.sqlite", filepath.Join(plan.Rollback, "accounts.sqlite")); err != nil {
		t.Fatal(err)
	}
	if err := root.Rename(filepath.Join(plan.Install, "accounts.sqlite"), "accounts.sqlite"); err != nil {
		t.Fatal(err)
	}
	if err := root.Remove(filepath.Join(plan.Rollback, "accounts.sqlite")); err != nil {
		t.Fatal(err)
	}
	if err := root.Close(); err != nil {
		t.Fatal(err)
	}

	if err := RecoverInterruptedActivation(dir); err == nil {
		t.Fatal("recovery accepted a missing original copy while a different version was live")
	}
	if !RecoveryPending(dir) {
		t.Fatal("unrecoverable transaction cleared the startup-blocking journal")
	}
	if got, err := os.ReadFile(filepath.Join(dir, "accounts.sqlite")); err != nil || string(got) != string(newBytes) {
		t.Fatalf("recovery changed the live file after refusing: %v", err)
	}
}

func TestInterruptedActivationAcceptsAlreadyRestoredOriginal(t *testing.T) {
	dir, stage := makeActivationFixture(t)
	oldBytes, err := os.ReadFile(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	newBytes, err := os.ReadFile(filepath.Join(dir, stage, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	oldHash := sha256.Sum256(oldBytes)
	newHash := sha256.Sum256(newBytes)
	entry := activationFile{Name: "accounts.sqlite", SHA256: hex.EncodeToString(newHash[:]), Size: int64(len(newBytes)),
		HadOriginal: true, OriginalSHA256: hex.EncodeToString(oldHash[:]), OriginalSize: int64(len(oldBytes))}
	root, plan := makeInterruptedActivationJournal(t, dir, stage, entry, newBytes)
	if err := root.Rename("accounts.sqlite", filepath.Join(plan.Rollback, "accounts.sqlite")); err != nil {
		t.Fatal(err)
	}
	if err := root.Rename(filepath.Join(plan.Install, "accounts.sqlite"), "accounts.sqlite"); err != nil {
		t.Fatal(err)
	}
	quarantine := filepath.Join(plan.Rollback, ".interrupted-new-accounts.sqlite")
	if err := root.Rename("accounts.sqlite", quarantine); err != nil {
		t.Fatal(err)
	}
	if err := root.Rename(filepath.Join(plan.Rollback, "accounts.sqlite"), "accounts.sqlite"); err != nil {
		t.Fatal(err)
	}
	if err := root.Close(); err != nil {
		t.Fatal(err)
	}

	if err := RecoverInterruptedActivation(dir); err != nil {
		t.Fatalf("idempotent recovery rejected an already restored, hash-matching file: %v", err)
	}
	if RecoveryPending(dir) {
		t.Fatal("verified idempotent recovery retained the journal")
	}
	if got, err := os.ReadFile(filepath.Join(dir, "accounts.sqlite")); err != nil || string(got) != string(oldBytes) {
		t.Fatalf("original version changed: %v", err)
	}
	if got, err := os.ReadFile(filepath.Join(dir, quarantine)); err != nil || string(got) != string(newBytes) {
		t.Fatalf("displaced new version was not preserved: %v", err)
	}
}

func TestInterruptedActivationWithoutOriginalProvesNewFileDisposition(t *testing.T) {
	t.Run("quarantines expected new file", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.Chmod(dir, 0700); err != nil {
			t.Fatal(err)
		}
		stage := "LightIsle-RestoredMetadata-new-file"
		content := []byte(`{"root":"selected"}`)
		hash := sha256.Sum256(content)
		entry := activationFile{Name: "shared-root.json", SHA256: hex.EncodeToString(hash[:]), Size: int64(len(content))}
		root, plan := makeInterruptedActivationJournal(t, dir, stage, entry, content)
		if err := root.Rename(filepath.Join(plan.Install, entry.Name), entry.Name); err != nil {
			t.Fatal(err)
		}
		if err := root.Close(); err != nil {
			t.Fatal(err)
		}

		if err := RecoverInterruptedActivation(dir); err != nil {
			t.Fatalf("recover expected new file: %v", err)
		}
		if RecoveryPending(dir) {
			t.Fatal("verified new-file quarantine kept the journal")
		}
		if _, err := os.Lstat(filepath.Join(dir, entry.Name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("new file remained live after restoring absence: %v", err)
		}
		if got, err := os.ReadFile(filepath.Join(dir, plan.Rollback, ".interrupted-new-"+entry.Name)); err != nil || string(got) != string(content) {
			t.Fatalf("new file was not retained in quarantine: %v", err)
		}
	})

	t.Run("preserves unknown live file and pending journal", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.Chmod(dir, 0700); err != nil {
			t.Fatal(err)
		}
		stage := "LightIsle-RestoredMetadata-new-file"
		content := []byte(`{"root":"selected"}`)
		unknown := []byte(`{"root":"foreign"}`)
		hash := sha256.Sum256(content)
		entry := activationFile{Name: "shared-root.json", SHA256: hex.EncodeToString(hash[:]), Size: int64(len(content))}
		root, _ := makeInterruptedActivationJournal(t, dir, stage, entry, content)
		if err := root.Close(); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, entry.Name), unknown, 0600); err != nil {
			t.Fatal(err)
		}

		if err := RecoverInterruptedActivation(dir); err == nil {
			t.Fatal("recovery accepted an unknown file in a path that had no original")
		}
		if !RecoveryPending(dir) {
			t.Fatal("unrecognized file disposition cleared the journal")
		}
		if got, err := os.ReadFile(filepath.Join(dir, entry.Name)); err != nil || string(got) != string(unknown) {
			t.Fatalf("recovery removed or changed the unknown file: %v", err)
		}
	})
}

func makeInterruptedActivationJournal(t *testing.T, dir, stage string, entry activationFile, pending []byte) (*os.Root, activationPlan) {
	t.Helper()
	tx := "1234567890abcdef"
	plan := activationPlan{Operation: "activate", TransactionID: tx, Stage: stage,
		Install: activationPrefix + tx, Rollback: rollbackPrefix + tx, Files: []activationFile{entry}}
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := root.Mkdir(plan.Install, 0700); err != nil {
		t.Fatal(err)
	}
	if err := root.Mkdir(plan.Rollback, 0700); err != nil {
		t.Fatal(err)
	}
	if pending != nil {
		if err := os.WriteFile(filepath.Join(dir, plan.Install, entry.Name), pending, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := saveActivationPlan(root, activationJournalName, plan); err != nil {
		t.Fatal(err)
	}
	return root, plan
}

func TestOfflineActivationRejectsCorruptAndInvalidStages(t *testing.T) {
	dir, stage := makeActivationFixture(t)
	original, err := os.ReadFile(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	staged := filepath.Join(dir, stage, "accounts.sqlite")
	if err = os.WriteFile(staged, []byte("invalid-db"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = ActivateStagedMetadata(dir, stage); err == nil {
		t.Fatal("corrupted snapshot activated")
	}
	current, err := os.ReadFile(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if string(current) != string(original) {
		t.Fatal("active account database changed on failed verification")
	}
	if RecoveryPending(dir) {
		t.Fatal("failed preflight left a journal")
	}
	if _, err := ActivateStagedMetadata(dir, "../"+stage); err == nil {
		t.Fatal("traversal stage accepted")
	}
}
