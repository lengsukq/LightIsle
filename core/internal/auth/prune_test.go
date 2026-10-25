package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"path/filepath"
	"testing"
	"time"
)

func countRows(t *testing.T, s *Store, query string, args ...any) int {
	t.Helper()
	var n int
	if err := s.db.QueryRow(query, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// PruneExpired is the periodic sweep that keeps sessions and both share
// tables bounded: expired rows must go, live rows must stay.
func TestPruneExpiredRemovesOnlyExpiredRows(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	stale, err := store.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	live, err := store.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}

	past := time.Now().Add(-time.Hour).Unix()
	staleDigest := sha256.Sum256([]byte(stale))
	if _, err := store.db.Exec("UPDATE sessions SET expires_at=? WHERE id=?", past, staleDigest[:]); err != nil {
		t.Fatal(err)
	}

	// One expired share row in each share table.
	var userID int
	if err := store.db.QueryRow("SELECT id FROM users LIMIT 1").Scan(&userID); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"file_shares", "root_file_shares"} {
		id := make([]byte, 16)
		if _, err := rand.Read(id); err != nil {
			t.Fatal(err)
		}
		query := "INSERT INTO " + table + "(id,user_id,file_path,file_identity,created_at,expires_at) VALUES (?,?,?,?,?,?)"
		args := []any{id, userID, "photos/a.txt", "dev:1:2:3", past - 10, past}
		if table == "root_file_shares" {
			query = "INSERT INTO " + table + "(id,user_id,root_id,root_generation,file_path,file_identity,created_at,expires_at) VALUES (?,?,?,?,?,?,?,?)"
			args = []any{id, userID, "0123456789abcdef0123456789abcdef", 1, "photos/a.txt", "dev:1:2:3", past - 10, past}
		}
		if _, err := store.db.Exec(query, args...); err != nil {
			t.Fatalf("seed %s: %v", table, err)
		}
	}

	if err := store.PruneExpired(time.Now()); err != nil {
		t.Fatal(err)
	}
	if n := countRows(t, store, "SELECT COUNT(*) FROM sessions"); n != 1 {
		t.Fatalf("sessions left = %d, want only the live one", n)
	}
	liveDigest := sha256.Sum256([]byte(live))
	var expires int64
	if err := store.db.QueryRow("SELECT expires_at FROM sessions WHERE id=?", liveDigest[:]).Scan(&expires); err != nil {
		t.Fatalf("live session pruned: %v", err)
	}
	for _, table := range []string{"file_shares", "root_file_shares"} {
		if n := countRows(t, store, "SELECT COUNT(*) FROM "+table); n != 0 {
			t.Fatalf("%s left = %d, want 0", table, n)
		}
	}
	// The live session still authenticates.
	if _, ok := store.Identity(live); !ok {
		t.Fatal("live session must keep working after pruning")
	}
	if _, ok := store.Identity(stale); ok {
		t.Fatal("expired session must be rejected")
	}
}
