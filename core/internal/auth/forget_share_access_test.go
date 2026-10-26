package auth

import (
	"path/filepath"
	"testing"
)

func TestRevokeDefaultShareAccessPreservesUserAccountsAndOtherRoots(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	result, err := store.db.Exec("INSERT INTO users(username,role,enabled,salt,password_hash,created_at) VALUES('fixture','member',1,?,?,1)", []byte("salt"), []byte("hash"))
	if err != nil {
		t.Fatal(err)
	}
	uid, err := result.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec("INSERT INTO sessions(id,user_id,expires_at,created_at) VALUES(?,?,99,1)", []byte("session"), uid); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec("INSERT INTO dav_credentials(user_id,label,digest,created_at) VALUES(?,?,?,1)", uid, "test", []byte("digest")); err != nil {
		t.Fatal(err)
	}
	id := "abcdef0123456789abcdef0123456789"
	ops := []struct {
		sql  string
		args []any
	}{
		{"INSERT INTO file_grants(user_id,path,can_write) VALUES(?,?,1)", []any{uid, "."}},
		{"INSERT INTO file_shares(id,user_id,file_path,file_identity,kind,created_at,expires_at,password_hash,max_downloads,download_count) VALUES(?,?,?,?,?,1,99,?,3,1)", []any{[]byte("token"), uid, "secret.txt", "inode", "file", []byte("password")}},
		{"INSERT INTO root_file_grants(user_id,root_id,path,can_write) VALUES(?,?,'.',1)", []any{uid, id}},
		{"INSERT INTO root_file_shares(id,user_id,root_id,root_generation,file_path,file_identity,created_at,expires_at) VALUES(?,?,?,1,'secret.txt','inode',1,99)", []any{[]byte("root"), uid, id}},
	}
	for _, op := range ops {
		if _, err := store.db.Exec(op.sql, op.args...); err != nil {
			t.Fatal(err)
		}
	}
	if err := store.RevokeDefaultShareAccess(); err != nil {
		t.Fatal(err)
	}
	if err := store.RevokeDefaultShareAccess(); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		table string
		want  int
	}{
		{"file_grants", 0}, {"file_shares", 0}, {"root_file_grants", 1}, {"root_file_shares", 1},
		{"users", 1}, {"sessions", 1}, {"dav_credentials", 1},
	} {
		var actual int
		if err := store.db.QueryRow("SELECT count(*) FROM " + tc.table).Scan(&actual); err != nil {
			t.Fatal(err)
		}
		if actual != tc.want {
			t.Fatalf("%s: got %d want %d", tc.table, actual, tc.want)
		}
	}
	var oldTable int
	if err := store.db.QueryRow("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='legacy_share_access_archives'").Scan(&oldTable); err != nil {
		t.Fatal(err)
	}
	if oldTable != 0 {
		t.Fatal("legacy permission history archive should not be created on clean Beta installation")
	}
}
