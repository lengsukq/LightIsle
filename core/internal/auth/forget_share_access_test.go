package auth

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func TestForgetShareAccessRevokesOnlyAbandonedSharePermissions(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	result, err := s.db.Exec(
		"INSERT INTO users(username,role,enabled,salt,password_hash,created_at) VALUES('fixture','member',1,?,?,1)",
		[]byte("salt"), []byte("hash"),
	)
	if err != nil {
		t.Fatal(err)
	}
	userID, err := result.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec("INSERT INTO sessions(id,user_id,expires_at,created_at) VALUES(?,?,99,1)", []byte("session"), userID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec("INSERT INTO dav_credentials(user_id,label,digest,created_at) VALUES(?,?,?,1)", userID, "fixture", []byte("dav-digest")); err != nil {
		t.Fatal(err)
	}
	rootID := "abcdef0123456789abcdef0123456789"
	statements := []struct {
		query string
		args  []any
	}{
		{"INSERT INTO file_grants(user_id,path,can_write) VALUES(?,?,1)", []any{userID, "."}},
		{"INSERT INTO file_shares(id,user_id,file_path,file_identity,kind,created_at,expires_at,password_hash,max_downloads,download_count) VALUES(?,?,?,?,?,1,99,?,3,1)", []any{[]byte("token-digest-must-not-be-archived"), userID, "secret.txt", "file-identity", "file", []byte("password-verifier-must-not-be-archived")}},
		{"INSERT INTO root_file_grants(user_id,root_id,path,can_write) VALUES(?,?,'.',1)", []any{userID, rootID}},
		{"INSERT INTO root_file_shares(id,user_id,root_id,root_generation,file_path,file_identity,created_at,expires_at) VALUES(?,?,?,1,'secret.txt','id',1,99)", []any{[]byte("rootshare"), userID, rootID}},
	}
	for _, s1 := range statements {
		if _, err := s.db.Exec(s1.query, s1.args...); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.ForgetLegacyShareAccess(); err != nil {
		t.Fatal(err)
	}
	count := func(table string) int {
		t.Helper()
		var n int
		if err := s.db.QueryRow("SELECT count(*) FROM " + table).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if count("file_grants") != 0 || count("file_shares") != 0 ||
		count("root_file_grants") != 1 || count("root_file_shares") != 1 {
		t.Fatal("legacy cleanup damaged unrelated scoped permissions")
	}
	if count("users") != 1 || count("sessions") != 1 || count("dav_credentials") != 1 {
		t.Fatal("legacy cleanup changed accounts, sessions, or WebDAV credentials")
	}
	var grantJSON, shareJSON string
	var archivedAt int64
	if err := s.db.QueryRow("SELECT archived_at,grants_json,shares_json FROM legacy_share_access_archives ORDER BY id DESC LIMIT 1").Scan(&archivedAt, &grantJSON, &shareJSON); err != nil {
		t.Fatal(err)
	}
	var archivedGrants []legacyGrantSnapshot
	var archivedShares []legacyShareSnapshot
	if err := json.Unmarshal([]byte(grantJSON), &archivedGrants); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(shareJSON), &archivedShares); err != nil {
		t.Fatal(err)
	}
	if archivedAt <= 0 || len(archivedGrants) != 1 || archivedGrants[0].UserID != userID || archivedGrants[0].Path != "." || !archivedGrants[0].CanWrite {
		t.Fatalf("legacy grant history not preserved: %+v at %d", archivedGrants, archivedAt)
	}
	if len(archivedShares) != 1 || archivedShares[0].UserID != userID || archivedShares[0].Path != "secret.txt" ||
		archivedShares[0].FileIdentity != "file-identity" || archivedShares[0].MaxDownloads != 3 || archivedShares[0].DownloadCount != 1 {
		t.Fatalf("non-secret share history not preserved: %+v", archivedShares)
	}
	if strings.Contains(grantJSON+shareJSON, "token-digest-must-not-be-archived") ||
		strings.Contains(grantJSON+shareJSON, "password-verifier-must-not-be-archived") {
		t.Fatal("archive retained a token digest or password verifier")
	}
	if err := s.ForgetLegacyShareAccess(); err != nil {
		t.Fatal(err)
	}
	if count("legacy_share_access_archives") != 1 {
		t.Fatal("empty cleanup created an empty history entry")
	}
	if err := s.ForgetRootAccess("invalid"); err != ErrInput {
		t.Fatalf("accepted invalid root ID: %v", err)
	}
	if err := s.ForgetRootAccess(rootID); err != nil {
		t.Fatal(err)
	}
	if count("root_file_grants") != 0 || count("root_file_shares") != 0 ||
		count("users") != 1 {
		t.Fatal("root access not revoked or account was deleted")
	}
}

func TestForgetLegacyShareAccessArchiveFailureRollsBackRevocation(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	result, err := s.db.Exec(
		"INSERT INTO users(username,role,enabled,salt,password_hash,created_at) VALUES('fixture','member',1,?,?,1)",
		[]byte("salt"), []byte("hash"),
	)
	if err != nil {
		t.Fatal(err)
	}
	userID, err := result.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec("INSERT INTO file_grants(user_id,path,can_write) VALUES(?,?,1)", userID, "Private"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec("DROP TABLE legacy_share_access_archives"); err != nil {
		t.Fatal(err)
	}
	if err := s.ForgetLegacyShareAccess(); err == nil {
		t.Fatal("revocation succeeded without its required history archive")
	}
	var grants, shares int
	if err := s.db.QueryRow("SELECT count(*) FROM file_grants").Scan(&grants); err != nil {
		t.Fatal(err)
	}
	if err := s.db.QueryRow("SELECT count(*) FROM file_shares").Scan(&shares); err != nil {
		t.Fatal(err)
	}
	if grants != 1 || shares != 0 {
		t.Fatalf("archive failure partially revoked active access: grants=%d shares=%d", grants, shares)
	}
}

func TestForgetLegacyShareAccessKeepsOnlyEightArchives(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	result, err := s.db.Exec(
		"INSERT INTO users(username,role,enabled,salt,password_hash,created_at) VALUES('fixture','member',1,?,?,1)",
		[]byte("salt"), []byte("hash"),
	)
	if err != nil {
		t.Fatal(err)
	}
	userID, err := result.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 10; i++ {
		if _, err := s.db.Exec("INSERT INTO file_grants(user_id,path,can_write) VALUES(?,?,?)", userID, fmt.Sprintf("folder%d", i), i%2); err != nil {
			t.Fatal(err)
		}
		if err := s.ForgetLegacyShareAccess(); err != nil {
			t.Fatal(err)
		}
	}
	var count int
	if err := s.db.QueryRow("SELECT count(*) FROM legacy_share_access_archives").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 8 {
		t.Fatalf("archive count = %d, want latest eight", count)
	}
}
