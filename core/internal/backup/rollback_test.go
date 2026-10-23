package backup

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func TestOfflineRollbackPreservesCurrentWritesAndPreviousVersion(t *testing.T) {
	dir, stage := makeActivationFixture(t)
	rollbackDir, err := ActivateStagedMetadata(dir, stage)
	if err != nil {
		t.Fatal(err)
	}
	transactionID := strings.TrimPrefix(filepath.Base(rollbackDir), rollbackPrefix)

	active, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if username, err := active.ResetFirstAdminPassword("post-activation-password-123"); err != nil || username != "replacement" {
		t.Fatalf("record a post-activation database write: %q %v", username, err)
	}
	if err := active.Close(); err != nil {
		t.Fatal(err)
	}
	currentBytes, err := os.ReadFile(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	walPath := filepath.Join(dir, "accounts.sqlite-wal")
	walBytes := []byte("post-activation WAL retained as part of the current version")
	if err := os.WriteFile(walPath, walBytes, 0600); err != nil {
		t.Fatal(err)
	}

	listed, err := ListMetadataRollbacks(dir)
	if err != nil || len(listed.Transactions) != 1 {
		t.Fatalf("list activated transaction: %+v %v", listed, err)
	}
	record := listed.Transactions[0]
	if record.ID != transactionID || record.State != "eligible" || !record.CanRollback || record.FileCount != 1 {
		t.Fatalf("unexpected rollback inventory: %+v", record)
	}

	result, err := RollbackMetadata(dir, transactionID)
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != rollbackStateRolledBack || result.PreservedCurrent != filepath.Join(rollbackDir, rollbackAfterName) {
		t.Fatalf("rollback result: %+v", result)
	}
	if len(result.RestoredPrevious) != 1 || result.RestoredPrevious[0] != "accounts.sqlite" {
		t.Fatalf("previous files not reported: %+v", result.RestoredPrevious)
	}
	if RecoveryPending(dir) {
		t.Fatal("successful rollback left startup blocked")
	}
	if got, err := os.ReadFile(filepath.Join(result.PreservedCurrent, "accounts.sqlite")); err != nil || string(got) != string(currentBytes) {
		t.Fatalf("post-activation database write was not retained: %v", err)
	}
	if got, err := os.ReadFile(filepath.Join(result.PreservedCurrent, "accounts.sqlite-wal")); err != nil || string(got) != string(walBytes) {
		t.Fatalf("post-activation WAL was not retained: %v", err)
	}
	if _, err := os.Lstat(walPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("current WAL was left beside the restored old DB: %v", err)
	}
	previous, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	username, err := previous.FirstAdminUsername()
	previous.Close()
	if err != nil || username != "original" {
		t.Fatalf("previous account version not restored: %q %v", username, err)
	}
	listed, err = ListMetadataRollbacks(dir)
	if err != nil || len(listed.Transactions) != 1 || listed.Transactions[0].State != rollbackStateRolledBack || listed.Transactions[0].CanRollback {
		t.Fatalf("completed transaction not listed as rolled back: %+v %v", listed, err)
	}
}

func TestOfflineRollbackRejectsLegacyAndCorruptReceiptsBeforeMutation(t *testing.T) {
	dir, stage := makeActivationFixture(t)
	rollbackDir, err := ActivateStagedMetadata(dir, stage)
	if err != nil {
		t.Fatal(err)
	}
	transactionID := strings.TrimPrefix(filepath.Base(rollbackDir), rollbackPrefix)
	legacyName := rollbackPrefix + "0000000000000000"
	if err := os.Mkdir(filepath.Join(dir, legacyName), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, legacyName, "accounts.sqlite"), []byte("unclaimed legacy state"), 0600); err != nil {
		t.Fatal(err)
	}
	listed, err := ListMetadataRollbacks(dir)
	if err != nil {
		t.Fatal(err)
	}
	var foundLegacy bool
	for _, entry := range listed.Transactions {
		if entry.ID == "0000000000000000" {
			foundLegacy = entry.State == "not_eligible" && !entry.CanRollback && entry.Reason == "receipt_missing"
		}
	}
	if !foundLegacy {
		t.Fatalf("legacy directory was not conservatively rejected: %+v", listed.Transactions)
	}

	activeBefore, err := os.ReadFile(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(rollbackDir, "accounts.sqlite"), []byte("foreign replacement"), 0600); err != nil {
		t.Fatal(err)
	}
	listed, err = ListMetadataRollbacks(dir)
	if err != nil {
		t.Fatal(err)
	}
	var foundInvalid bool
	for _, entry := range listed.Transactions {
		if entry.ID == transactionID {
			foundInvalid = entry.State == "invalid" && !entry.CanRollback
		}
	}
	if !foundInvalid {
		t.Fatalf("corrupt previous bytes remained eligible: %+v", listed.Transactions)
	}
	if _, err := RollbackMetadata(dir, transactionID); err == nil {
		t.Fatal("rollback accepted modified retained previous database")
	}
	activeAfter, err := os.ReadFile(filepath.Join(dir, "accounts.sqlite"))
	if err != nil || string(activeAfter) != string(activeBefore) {
		t.Fatalf("rejected rollback modified active database: %v", err)
	}
	if RecoveryPending(dir) {
		t.Fatal("preflight rejection left a transaction journal")
	}
}

func TestOfflineRollbackRecoveryCompletesInterruptedTransaction(t *testing.T) {
	dir, stage := makeActivationFixture(t)
	rollbackDir, err := ActivateStagedMetadata(dir, stage)
	if err != nil {
		t.Fatal(err)
	}
	transactionID := strings.TrimPrefix(filepath.Base(rollbackDir), rollbackPrefix)
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := loadRollbackReceipt(root, filepath.Base(rollbackDir), nil, false)
	if err != nil {
		t.Fatal(err)
	}
	files := make([]rollbackJournalFile, 0, len(receipt.Files)*3)
	for _, name := range rollbackNames(receipt.Files) {
		file, err := captureRollbackFile(root, name)
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, file)
	}
	plan := activationPlan{Operation: "rollback", TransactionID: transactionID, Stage: receipt.Stage,
		Install: rollbackInstallPrefix + transactionID, Rollback: filepath.Base(rollbackDir), Files: receipt.Files, RollbackFiles: files}
	if err := saveActivationPlan(root, activationJournalName, plan); err != nil {
		t.Fatal(err)
	}
	if err := markRecoverySessionRevocation(root); err != nil {
		t.Fatal(err)
	}
	rollbackRoot, err := root.OpenRoot(plan.Rollback)
	if err != nil {
		t.Fatal(err)
	}
	if err := rollbackRoot.Mkdir(rollbackAfterName, 0700); err != nil {
		t.Fatal(err)
	}
	rollbackRoot.Close()
	if err := root.Rename("accounts.sqlite", filepath.Join(plan.Rollback, rollbackAfterName, "accounts.sqlite")); err != nil {
		t.Fatal(err)
	}
	if err := syncPrivateDir(root); err != nil {
		t.Fatal(err)
	}
	if err := root.Close(); err != nil {
		t.Fatal(err)
	}
	if !RecoveryPending(dir) {
		t.Fatal("interrupted rollback did not block Core startup")
	}
	listed, err := ListMetadataRollbacks(dir)
	if err != nil || !listed.RecoveryPending || !listed.MetadataRecoveryPending || !listed.SessionCleanupPending ||
		len(listed.Transactions) == 0 || listed.Transactions[0].State != "interrupted" || listed.Transactions[0].CanRollback {
		t.Fatalf("mixed journal and session cleanup were not reported conservatively: %+v %v", listed, err)
	}
	inspection, err := InspectOfflineRecovery(dir)
	if err != nil || !inspection.MetadataRecoveryPending || !inspection.SessionCleanupPending ||
		inspection.PendingOperation != "rollback" || inspection.PendingTransactionID != transactionID {
		t.Fatalf("mixed recovery inspection lost journal identity: %+v %v", inspection, err)
	}
	if err := RecoverInterruptedActivation(dir); err != nil {
		t.Fatal(err)
	}
	if RecoveryPending(dir) {
		t.Fatal("completed interrupted rollback kept startup blocked")
	}
	previous, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	username, err := previous.FirstAdminUsername()
	previous.Close()
	if err != nil || username != "original" {
		t.Fatalf("interrupted rollback did not restore previous version: %q %v", username, err)
	}
	if _, err := os.Stat(filepath.Join(rollbackDir, rollbackAfterName, "accounts.sqlite")); err != nil {
		t.Fatalf("current version not retained after recovery: %v", err)
	}
}

func TestOfflineRollbackRequiresStoppedCoreAndPrivateOwnedDataDir(t *testing.T) {
	dir, stage := makeActivationFixture(t)
	rollbackDir, err := ActivateStagedMetadata(dir, stage)
	if err != nil {
		t.Fatal(err)
	}
	transactionID := strings.TrimPrefix(filepath.Base(rollbackDir), rollbackPrefix)
	locked, err := LockDataDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := RollbackMetadata(dir, transactionID); !errors.Is(err, ErrAppRunning) {
		t.Fatalf("rollback ran with Core lock held: %v", err)
	}
	locked.Close()
	if RecoveryPending(dir) {
		t.Fatal("rejected live-Core rollback left a journal")
	}
	if err := os.Chmod(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if _, err := RollbackMetadata(dir, transactionID); err == nil || !strings.Contains(err.Error(), "not_private") {
		t.Fatalf("non-private data directory accepted: %v", err)
	}
	info, err := os.Stat(dir)
	if err != nil || info.Mode().Perm() != 0755 {
		t.Fatalf("unsafe existing directory was silently chmod'd: %v %v", info, err)
	}
}
