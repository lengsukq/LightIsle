package backup

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	_ "github.com/mattn/go-sqlite3"
)

func TestRollbackFollowsActiveTransactionChain(t *testing.T) {
	dir, stage := makeActivationFixture(t)
	first, err := ActivateStagedMetadata(dir, stage)
	if err != nil {
		t.Fatal(err)
	}
	second, err := ActivateStagedMetadata(dir, stage)
	if err != nil {
		t.Fatal(err)
	}
	firstID := strings.TrimPrefix(filepath.Base(first), rollbackPrefix)
	secondID := strings.TrimPrefix(filepath.Base(second), rollbackPrefix)
	before, err := os.ReadFile(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := RollbackMetadata(dir, firstID); err == nil {
		t.Fatal("superseded activation accepted")
	}
	after, _ := os.ReadFile(filepath.Join(dir, "accounts.sqlite"))
	if string(before) != string(after) {
		t.Fatal("rejected stale rollback changed current database")
	}
	assertEligible := func(want string) {
		t.Helper()
		listed, err := ListMetadataRollbacks(dir)
		if err != nil {
			t.Fatal(err)
		}
		var eligible []string
		for _, transaction := range listed.Transactions {
			if transaction.CanRollback {
				eligible = append(eligible, transaction.ID)
			}
		}
		if (want == "" && len(eligible) != 0) || (want != "" && (len(eligible) != 1 || eligible[0] != want)) {
			t.Fatalf("active rollback = %v, want %q", eligible, want)
		}
	}
	assertEligible(secondID)
	if _, err := RollbackMetadata(dir, secondID); err != nil {
		t.Fatal(err)
	}
	assertEligible(firstID)
	if _, err := RollbackMetadata(dir, firstID); err != nil {
		t.Fatal(err)
	}
	assertEligible("")
	store, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	name, err := store.FirstAdminUsername()
	if err != nil || name != "original" {
		t.Fatalf("last rollback did not restore original: %q %v", name, err)
	}
}

func TestRollbackNeverResurrectsOriginalBrowserSession(t *testing.T) {
	dir, stage := makeActivationFixture(t)
	store, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	cookie, err := store.Login("original", "original-password-123")
	if err != nil {
		t.Fatal(err)
	}
	_, capability, err := store.CreateFileShare(cookie, "some-file.txt", "test-identity", auth.ShareKindFile, 1, auth.SharePolicy{})
	if err != nil {
		t.Fatal(err)
	}
	store.Close()
	rollback, err := ActivateStagedMetadata(dir, stage)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := RollbackMetadata(dir, strings.TrimPrefix(filepath.Base(rollback), rollbackPrefix)); err != nil {
		t.Fatal(err)
	}
	store, err = auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, valid := store.Identity(cookie); valid {
		t.Fatal("revoked pre-activation cookie became valid after rollback")
	}
	if _, err := store.ResolveFileShare(capability); err != auth.ErrNotFound {
		t.Fatalf("old share capability resurrected after rollback: %v", err)
	}
	if _, err := store.Login("original", "original-password-123"); err != nil {
		t.Fatal("original account cannot sign in after rollback:", err)
	}
	if listed, err := ListMetadataRollbacks(dir); err != nil || len(listed.Transactions) != 1 || listed.Transactions[0].State != rollbackStateRolledBack {
		t.Fatalf("immutable receipt copies changed during session cleanup: %+v %v", listed, err)
	}
}

func TestRecoverySessionCleanupFailureKeepsDurableMarker(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "accounts.sqlite"), []byte("corrupt database"), 0600); err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := markRecoverySessionRevocation(root); err != nil {
		t.Fatal(err)
	}
	root.Close()
	if err := FinalizeRecoverySessions(dir); err == nil {
		t.Fatal("corrupt recovered accounts exposed without revocation")
	}
	if _, err := os.Stat(filepath.Join(dir, revokeRecoverySessionsName)); err != nil {
		t.Fatal("failed cleanup lost its durable marker:", err)
	}
	if !RecoveryPending(dir) || MetadataActivationPending(dir) || !SessionCleanupPending(dir) {
		t.Fatalf("marker-only recovery state was misclassified: pending=%v metadata=%v cleanup=%v",
			RecoveryPending(dir), MetadataActivationPending(dir), SessionCleanupPending(dir))
	}
	listed, err := ListMetadataRollbacks(dir)
	if err != nil || !listed.RecoveryPending || listed.MetadataRecoveryPending || !listed.SessionCleanupPending {
		t.Fatalf("marker-only rollback inventory lost cleanup state: %+v %v", listed, err)
	}
	inspection, err := InspectOfflineRecovery(dir)
	if err != nil || !inspection.RecoveryPending || inspection.MetadataRecoveryPending ||
		!inspection.SessionCleanupPending || inspection.PendingOperation != "session_cleanup" {
		t.Fatalf("marker-only inspection did not identify session cleanup: %+v %v", inspection, err)
	}
}

func TestRecoverySessionCleanupRevokesRootFileShares(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite3", filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		`CREATE TABLE sessions(id TEXT PRIMARY KEY)`,
		`INSERT INTO sessions VALUES('session')`,
		`CREATE TABLE file_shares(id TEXT PRIMARY KEY)`,
		`INSERT INTO file_shares VALUES('legacy-share')`,
		`CREATE TABLE root_file_shares(id TEXT PRIMARY KEY,root_id TEXT,token_hash BLOB)`,
		`INSERT INTO root_file_shares VALUES('root-share','0123456789abcdef0123456789abcdef',x'736563726574')`,
	} {
		if _, err := db.Exec(statement); err != nil {
			db.Close()
			t.Fatalf("exec %q: %v", statement, err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := markRecoverySessionRevocation(root); err != nil {
		root.Close()
		t.Fatal(err)
	}
	if err := root.Close(); err != nil {
		t.Fatal(err)
	}
	if err := FinalizeRecoverySessions(dir); err != nil {
		t.Fatal(err)
	}
	db, err = sql.Open("sqlite3", filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, table := range []string{"sessions", "file_shares", "root_file_shares"} {
		var count int
		if err := db.QueryRow("SELECT COUNT(*) FROM " + table).Scan(&count); err != nil || count != 0 {
			t.Errorf("recovery left %d rows in %s: %v", count, table, err)
		}
	}
	if SessionCleanupPending(dir) {
		t.Fatal("successful capability cleanup left durable marker")
	}
}

func TestMarkerOnlyCleanupFailureStillAllowsRollbackFromCorruptAccounts(t *testing.T) {
	dir, stage := makeActivationFixture(t)
	rollbackDir, err := ActivateStagedMetadata(dir, stage)
	if err != nil {
		t.Fatal(err)
	}
	transactionID := strings.TrimPrefix(filepath.Base(rollbackDir), rollbackPrefix)
	if err := os.WriteFile(filepath.Join(dir, "accounts.sqlite"), []byte("corrupt current accounts"), 0600); err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := markRecoverySessionRevocation(root); err != nil {
		t.Fatal(err)
	}
	root.Close()

	listed, err := ListMetadataRollbacks(dir)
	if err != nil || !listed.RecoveryPending || listed.MetadataRecoveryPending || !listed.SessionCleanupPending {
		t.Fatalf("corrupt-account marker-only state was not listed: %+v %v", listed, err)
	}
	if len(listed.Transactions) != 1 || !listed.Transactions[0].CanRollback || listed.Transactions[0].ID != transactionID {
		t.Fatalf("verified previous database was hidden by session cleanup marker: %+v", listed.Transactions)
	}

	result, err := RollbackMetadata(dir, transactionID)
	if err != nil {
		t.Fatalf("offline rollback could not rescue corrupt current accounts: %+v %v", result, err)
	}
	if RecoveryPending(dir) || SessionCleanupPending(dir) {
		t.Fatal("successful rescue did not finish pending session cleanup")
	}
	previous, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	username, err := previous.FirstAdminUsername()
	previous.Close()
	if err != nil || username != "original" {
		t.Fatalf("rollback did not restore the verified previous account database: %q %v", username, err)
	}
}

func TestRollbackListPrioritizesCurrentVersionOverLegacyHistory(t *testing.T) {
	dir, stage := makeActivationFixture(t)
	for i := 0; i < rollbackListLimit+10; i++ {
		if err := os.Mkdir(filepath.Join(dir, rollbackPrefix+fmt.Sprintf("%016x", i)), 0700); err != nil {
			t.Fatal(err)
		}
	}
	current, err := ActivateStagedMetadata(dir, stage)
	if err != nil {
		t.Fatal(err)
	}
	listed, err := ListMetadataRollbacks(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !listed.Truncated || len(listed.Transactions) > rollbackListLimit || len(listed.Transactions) == 0 ||
		listed.Transactions[0].ID != strings.TrimPrefix(filepath.Base(current), rollbackPrefix) || !listed.Transactions[0].CanRollback {
		t.Fatalf("current actionable transaction hidden by legacy history: %+v", listed)
	}
}
