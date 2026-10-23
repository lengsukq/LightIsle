package auth

import (
	"path/filepath"
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
	rootID := "abcdef0123456789abcdef0123456789"
	statements := []struct {
		query string
		args  []any
	}{
		{"INSERT INTO file_grants(user_id,path,can_write) VALUES(?,?,1)", []any{userID, "."}},
		{"INSERT INTO file_shares(id,user_id,file_path,file_identity,created_at,expires_at) VALUES(?,?,?,?,1,99)", []any{[]byte("legacy"), userID, "secret.txt", "id"}},
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
