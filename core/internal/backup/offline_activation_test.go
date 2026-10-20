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
