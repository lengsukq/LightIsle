package auth

import (
	"encoding/hex"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func TestShareKindDirRoundTripAndLegacyDefault(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "accounts.sqlite")
	store, err := Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	admin, err := store.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.CreateFileShare(admin, "folder", "identity", "bogus", 1, SharePolicy{}); !errors.Is(err, ErrInput) {
		t.Fatalf("invalid kind accepted: %v", err)
	}
	_, dirToken, err := store.CreateFileShare(admin, "folder", "d:1:2", ShareKindDir, 1, SharePolicy{})
	if err != nil {
		t.Fatal(err)
	}
	access, err := store.ResolveFileShare(dirToken)
	if err != nil || access.Kind != ShareKindDir {
		t.Fatalf("dir kind lost on resolve: %+v %v", access, err)
	}
	listed, err := store.ListFileShares(admin)
	if err != nil || len(listed) != 1 || listed[0].Kind != ShareKindDir {
		t.Fatalf("dir kind lost on list: %+v %v", listed, err)
	}
	// Simulate a pre-migration database: same policy columns, no kind column.
	digest, err := hex.DecodeString(listed[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`DROP TABLE file_shares`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`CREATE TABLE file_shares(
		id BLOB PRIMARY KEY,
		user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		file_path TEXT NOT NULL,
		file_identity TEXT NOT NULL,
		password_hash BLOB,
		max_downloads INTEGER,
		download_count INTEGER,
		created_at INTEGER NOT NULL,
		expires_at INTEGER NOT NULL)`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`INSERT INTO file_shares(id,user_id,file_path,file_identity,download_count,created_at,expires_at)
		VALUES(?,?,?,?,0,?,?)`, digest, access.UserID, "folder", "d:1:2", access.ExpiresAt-3600, access.ExpiresAt); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	// Old rows must keep serving as single-file links after the migration.
	legacy, err := store.ResolveFileShare(dirToken)
	if err != nil || legacy.Kind != ShareKindFile {
		t.Fatalf("legacy row did not default to file kind: %+v %v", legacy, err)
	}
}

func TestFileSharePersistentCapabilityExpiryAndQuota(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "accounts.sqlite")
	store, err := Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	admin, err := store.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	share, token, err := store.CreateFileShare(admin, "some-file.txt", "inode-identity", ShareKindFile, 1, SharePolicy{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ResolveFileShare(token); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	got, err := store.ResolveFileShare(token)
	if err != nil || got.Path != "some-file.txt" || got.Identity != "inode-identity" {
		t.Fatalf("restarted store lost share: %+v %v", got, err)
	}
	if _, _, err := store.CreateFileShare(admin, "some-file.txt", "identity", ShareKindFile, 0, SharePolicy{}); !errors.Is(err, ErrInput) {
		t.Fatalf("zero expiry accepted: %v", err)
	}
	if _, _, err := store.CreateFileShare(admin, "some-file.txt", "identity", ShareKindFile, 169, SharePolicy{}); !errors.Is(err, ErrInput) {
		t.Fatalf("long expiry accepted: %v", err)
	}
	if _, _, err := store.CreateFileShare(admin, "../escape", "identity", ShareKindFile, 1, SharePolicy{}); !errors.Is(err, ErrInput) {
		t.Fatalf("invalid path accepted: %v", err)
	}
	// Simulate expiry without sleeping and verify expired tokens are refused.
	digest, err := hex.DecodeString(share.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec("UPDATE file_shares SET expires_at=? WHERE id=?", time.Now().Unix()-1, digest); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ResolveFileShare(token); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expired share still valid: %v", err)
	}
	list, err := store.ListFileShares(admin)
	if err != nil || len(list) != 0 {
		t.Fatalf("expired share still listed: %+v %v", list, err)
	}
	for i := 0; i < MaxFileShares; i++ {
		if _, _, err := store.CreateFileShare(admin, "some-file.txt", "identity", ShareKindFile, 1, SharePolicy{}); err != nil {
			t.Fatalf("share #%d failed: %v", i, err)
		}
	}
	if _, _, err := store.CreateFileShare(admin, "some-file.txt", "identity", ShareKindFile, 1, SharePolicy{}); !errors.Is(err, ErrExists) {
		t.Fatalf("share quota bypassed: %v", err)
	}
	listed, err := store.ListFileShares(admin)
	if err != nil || len(listed) != MaxFileShares {
		t.Fatalf("active links = %d, err=%v", len(listed), err)
	}
	if err := store.RevokeFileShare(admin, listed[0].ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.CreateFileShare(admin, "some-file.txt", "identity", ShareKindFile, 1, SharePolicy{}); err != nil {
		t.Fatalf("quota not reusable: %v", err)
	}
	var count int
	if err := store.db.QueryRow("SELECT COUNT(*) FROM file_shares WHERE expires_at<=?", time.Now().Unix()).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("expired shares not pruned: %d", count)
	}
}

func TestDisabledMemberSharesNeverReviveAfterReenable(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	admin, err := s.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	member, err := s.CreateUser(admin, "reader", "reader-password-12345", RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.SetFileGrant(admin, member.ID, "family", false); err != nil {
		t.Fatal(err)
	}
	reader, err := s.Login("reader", "reader-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	_, link, err := s.CreateFileShare(reader, "family/note.txt", "file-identity", ShareKindFile, 1, SharePolicy{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.ResolveFileShare(link); err != nil {
		t.Fatal(err)
	}
	if err := s.SetEnabled(admin, member.ID, false); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ResolveFileShare(link); !errors.Is(err, ErrNotFound) {
		t.Fatalf("disabled user's link still active: %v", err)
	}
	if err := s.SetEnabled(admin, member.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ResolveFileShare(link); !errors.Is(err, ErrNotFound) {
		t.Fatalf("re-enabled user restored deleted capability: %v", err)
	}
}

func TestShareIssuanceRejectsConcurrentRevocation(t *testing.T) {
	for _, change := range []string{"grant", "session", "account"} {
		t.Run(change, func(t *testing.T) {
			s, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			if err := s.Setup("owner", "owner-password-12345"); err != nil {
				t.Fatal(err)
			}
			admin, err := s.Login("owner", "owner-password-12345")
			if err != nil {
				t.Fatal(err)
			}
			member, err := s.CreateUser(admin, "reader", "reader-password-12345", RoleMember)
			if err != nil {
				t.Fatal(err)
			}
			if err := s.SetFileGrant(admin, member.ID, "family", false); err != nil {
				t.Fatal(err)
			}
			reader, err := s.Login("reader", "reader-password-12345")
			if err != nil {
				t.Fatal(err)
			}
			checked, resume := make(chan struct{}), make(chan struct{})
			s.afterShareAuthorization = func() { close(checked); <-resume }
			type attempt struct {
				token string
				err   error
			}
			done := make(chan attempt, 1)
			go func() {
				_, token, err := s.CreateFileShare(reader, "family/note.txt", "identity", ShareKindFile, 1, SharePolicy{})
				done <- attempt{token, err}
			}()
			<-checked
			switch change {
			case "grant":
				err = s.RemoveFileGrant(admin, member.ID, "family")
			case "session":
				s.Logout(reader)
			case "account":
				err = s.SetEnabled(admin, member.ID, false)
			}
			close(resume)
			result := <-done
			if err != nil {
				t.Fatal(err)
			}
			if !errors.Is(result.err, ErrForbidden) || result.token != "" {
				t.Fatalf("stale share issued after %s revocation: %+v", change, result)
			}
			s.afterShareAuthorization = nil
			if change == "grant" {
				if err := s.SetFileGrant(admin, member.ID, "family", false); err != nil {
					t.Fatal(err)
				}
			}
			if change == "account" {
				if err := s.SetEnabled(admin, member.ID, true); err != nil {
					t.Fatal(err)
				}
			}
			var count int
			if err := s.db.QueryRow("SELECT COUNT(*) FROM file_shares WHERE user_id=?", member.ID).Scan(&count); err != nil || count != 0 {
				t.Fatalf("stale capability survived reauthorization: %d %v", count, err)
			}
			fresh, err := s.Login("reader", "reader-password-12345")
			if err != nil {
				t.Fatal(err)
			}
			if _, _, err := s.CreateFileShare(fresh, "family/note.txt", "identity", ShareKindFile, 1, SharePolicy{}); err != nil {
				t.Fatalf("fresh authorized share rejected: %v", err)
			}
		})
	}
}
