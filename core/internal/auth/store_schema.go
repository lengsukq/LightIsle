package auth

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
)

func Open(path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	if err := os.Chmod(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	_ = f.Close()
	if err := os.Chmod(path, 0600); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite3", "file:"+path+"?_busy_timeout=5000&_journal_mode=WAL&_foreign_keys=1")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	stmts := []string{
		`PRAGMA synchronous=NORMAL`,
		`CREATE TABLE IF NOT EXISTS users(
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		username TEXT NOT NULL COLLATE NOCASE UNIQUE,
		role TEXT NOT NULL CHECK(role IN ('admin','member')),
		enabled INTEGER NOT NULL DEFAULT 1,
		salt BLOB NOT NULL, password_hash BLOB NOT NULL,
		created_at INTEGER NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS sessions(
		id BLOB PRIMARY KEY, user_id INTEGER NOT NULL,
		expires_at INTEGER NOT NULL, created_at INTEGER NOT NULL,
		FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE)`,
		`CREATE INDEX IF NOT EXISTS sessions_expiry ON sessions(expires_at)`,
		`CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id)`,
		`CREATE TABLE IF NOT EXISTS file_grants (
		user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		path TEXT NOT NULL, can_write INTEGER NOT NULL CHECK(can_write IN (0,1)),
		PRIMARY KEY(user_id,path))`,
		`CREATE TABLE IF NOT EXISTS root_file_grants (
		user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		root_id TEXT NOT NULL CHECK(length(root_id)=32),
		path TEXT NOT NULL,
		can_write INTEGER NOT NULL CHECK(can_write IN (0,1)),
		PRIMARY KEY(user_id,root_id,path))`,
		`CREATE INDEX IF NOT EXISTS root_file_grants_root ON root_file_grants(root_id,user_id)`,
		`CREATE TABLE IF NOT EXISTS user_storage_quotas (
		user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
		quota_bytes INTEGER NOT NULL CHECK(quota_bytes>=0 AND quota_bytes<=1125899906842624),
		updated_at INTEGER NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS user_storage_root_quotas (
		user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		root_id TEXT NOT NULL CHECK(length(root_id)=32),
		root_generation INTEGER NOT NULL CHECK(root_generation>0),
		quota_bytes INTEGER NOT NULL CHECK(quota_bytes>=0 AND quota_bytes<=1125899906842624),
		updated_at INTEGER NOT NULL,
		PRIMARY KEY(user_id,root_id,root_generation))`,
		`CREATE TABLE IF NOT EXISTS user_storage_locations (
		user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		category TEXT NOT NULL CHECK(category IN ('files','photos','videos')),
		root_id TEXT NOT NULL CHECK(length(root_id)=32),
		root_generation INTEGER NOT NULL CHECK(root_generation>0),
		relative_path TEXT NOT NULL,
		updated_at INTEGER NOT NULL,
		PRIMARY KEY(user_id,category),
		UNIQUE(root_id,relative_path))`,
		`CREATE TABLE IF NOT EXISTS user_storage_files (
		root_id TEXT NOT NULL,
		root_generation INTEGER NOT NULL,
		relative_path TEXT NOT NULL,
		user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		size_bytes INTEGER NOT NULL CHECK(size_bytes>=0),
		PRIMARY KEY(root_id,root_generation,relative_path))`,
		`CREATE INDEX IF NOT EXISTS user_storage_files_owner ON user_storage_files(user_id)`,
		`CREATE TABLE IF NOT EXISTS user_storage_file_identities (
		root_id TEXT NOT NULL,
		root_generation INTEGER NOT NULL,
		relative_path TEXT NOT NULL,
		identity TEXT NOT NULL CHECK(length(identity)=64),
		PRIMARY KEY(root_id,root_generation,relative_path),
		FOREIGN KEY(root_id,root_generation,relative_path)
		  REFERENCES user_storage_files(root_id,root_generation,relative_path)
		  ON UPDATE CASCADE ON DELETE CASCADE)`,
		`CREATE TABLE IF NOT EXISTS user_storage_reservations (
		id TEXT PRIMARY KEY,
		user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		root_id TEXT NOT NULL,
		root_generation INTEGER NOT NULL,
		relative_path TEXT NOT NULL,
		size_bytes INTEGER NOT NULL CHECK(size_bytes>=0),
		upload_id TEXT UNIQUE,
		created_at INTEGER NOT NULL)`,
		`CREATE INDEX IF NOT EXISTS user_storage_reservations_owner ON user_storage_reservations(user_id)`,
		`CREATE TABLE IF NOT EXISTS user_storage_detached_paths (
		root_id TEXT NOT NULL,
		path TEXT NOT NULL,
		PRIMARY KEY(root_id,path))`,
		`CREATE TABLE IF NOT EXISTS storage_switch_tasks (
		id TEXT PRIMARY KEY,
		user_id INTEGER NOT NULL,
		request BLOB NOT NULL,
		progress BLOB NOT NULL,
		committed INTEGER NOT NULL DEFAULT 0 CHECK(committed IN (0,1)),
		created_at INTEGER NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS file_shares(
		id BLOB PRIMARY KEY,
		user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		file_path TEXT NOT NULL,
		file_identity TEXT NOT NULL,
		kind TEXT NOT NULL DEFAULT 'file',
		created_at INTEGER NOT NULL,
		expires_at INTEGER NOT NULL)`,
		`CREATE INDEX IF NOT EXISTS file_shares_user ON file_shares(user_id,expires_at)`,
		`CREATE TABLE IF NOT EXISTS root_file_shares(
		id BLOB PRIMARY KEY,
		user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		root_id TEXT NOT NULL CHECK(length(root_id)=32),
		root_generation INTEGER NOT NULL DEFAULT 0 CHECK(root_generation>0),
		file_path TEXT NOT NULL,
		file_identity TEXT NOT NULL,
		kind TEXT NOT NULL DEFAULT 'file',
		created_at INTEGER NOT NULL,
		expires_at INTEGER NOT NULL)`,
		`CREATE INDEX IF NOT EXISTS root_file_shares_user_root ON root_file_shares(user_id,root_id,expires_at)`,
		`CREATE TABLE IF NOT EXISTS audit_events(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        actor_id INTEGER NOT NULL,
        action TEXT NOT NULL,
        target TEXT NOT NULL,
        outcome TEXT NOT NULL CHECK(outcome IN ('success','denied','failed')),
        created_at INTEGER NOT NULL)`,
		`CREATE INDEX IF NOT EXISTS audit_events_actor ON audit_events(actor_id,id)`,
		`CREATE TABLE IF NOT EXISTS dav_credentials(
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		label TEXT NOT NULL,
		digest BLOB NOT NULL,
		created_at INTEGER NOT NULL,
		last_used_at INTEGER NOT NULL DEFAULT 0)`,
		`CREATE INDEX IF NOT EXISTS dav_credentials_user ON dav_credentials(user_id)`,
		`CREATE TABLE IF NOT EXISTS shared_folder_albums(
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		root_id TEXT NOT NULL CHECK(length(root_id)=32),
		root_generation INTEGER NOT NULL CHECK(root_generation>0),
		owner_user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		album_name TEXT NOT NULL,
		member_user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		link_name TEXT NOT NULL,
		can_write INTEGER NOT NULL DEFAULT 0 CHECK(can_write IN (0,1)),
		created_at INTEGER NOT NULL,
		UNIQUE(root_id,root_generation,owner_user_id,album_name,member_user_id),
		UNIQUE(root_id,root_generation,member_user_id,link_name))`,
		`CREATE INDEX IF NOT EXISTS shared_folder_albums_member ON shared_folder_albums(root_id,member_user_id)`,
	}
	for _, q := range stmts {
		if _, err := db.Exec(q); err != nil {
			_ = db.Close()
			return nil, fmt.Errorf("init SQLite: %w", err)
		}
	}
	if err := ensureUploadCleanupSettings(db); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("init upload cleanup settings: %w", err)
	}
	if err := ensureRootShareGeneration(db); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("migrate root shares: %w", err)
	}
	if err := ensureSharePolicyColumns(db); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("migrate share policy: %w", err)
	}
	if err := ensureShareKindColumn(db); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("migrate share kind: %w", err)
	}
	if err := migratePerRootStorageQuotas(db); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("migrate per-root storage quotas: %w", err)
	}
	return &Store{db: db}, nil
}

// ensureSharePolicyColumns adds optional share protection to existing
// databases: a password verifier blob (salt||argon2id hash, empty when
// unset) and an atomic download counter. Older rows keep unlimited,
// password-free downloads.
func ensureSharePolicyColumns(db *sql.DB) error {
	for _, table := range []string{"file_shares", "root_file_shares"} {
		rows, err := db.Query("PRAGMA table_info(" + table + ")")
		if err != nil {
			return err
		}
		exists := make(map[string]bool)
		for rows.Next() {
			var cid, notNull, primaryKey int
			var name, columnType string
			var defaultValue any
			if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultValue, &primaryKey); err != nil {
				rows.Close()
				return err
			}
			exists[name] = true
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return err
		}
		rows.Close()
		for _, column := range []struct{ name, ddl string }{
			{"password_hash", "BLOB NOT NULL DEFAULT ''"},
			{"max_downloads", "INTEGER NOT NULL DEFAULT 0"},
			{"download_count", "INTEGER NOT NULL DEFAULT 0"},
		} {
			if exists[column.name] {
				continue
			}
			if _, err := db.Exec("ALTER TABLE " + table + " ADD COLUMN " + column.name + " " + column.ddl); err != nil {
				return err
			}
		}
	}
	return nil
}

// ensureRootShareGeneration invalidates any pre-generation v2 links. A
// rootID remains stable across explicit rebinds, so a link without the
// captured generation cannot safely identify the physical root it was issued
// for.
func ensureRootShareGeneration(db *sql.DB) error {
	rows, err := db.Query("PRAGMA table_info(root_file_shares)")
	if err != nil {
		return err
	}
	hasGeneration := false
	for rows.Next() {
		var cid, notNull, primaryKey int
		var name, columnType string
		var defaultValue any
		if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultValue, &primaryKey); err != nil {
			_ = rows.Close()
			return err
		}
		if name == "root_generation" {
			hasGeneration = true
		}
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return err
	}
	if err := rows.Close(); err != nil {
		return err
	}
	if !hasGeneration {
		if _, err := db.Exec("ALTER TABLE root_file_shares ADD COLUMN root_generation INTEGER NOT NULL DEFAULT 0"); err != nil {
			return err
		}
	}
	_, err = db.Exec("DELETE FROM root_file_shares WHERE root_generation<=0")
	return err
}

// ensureShareKindColumn adds the file/dir discriminator to both share tables.
// Existing rows keep their historical meaning ('file'), so old links survive
// the migration unchanged.
func ensureShareKindColumn(db *sql.DB) error {
	for _, table := range []string{"file_shares", "root_file_shares"} {
		rows, err := db.Query("PRAGMA table_info(" + table + ")")
		if err != nil {
			return err
		}
		hasKind := false
		for rows.Next() {
			var cid, notNull, primaryKey int
			var name, columnType string
			var defaultValue any
			if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultValue, &primaryKey); err != nil {
				_ = rows.Close()
				return err
			}
			if name == "kind" {
				hasKind = true
			}
		}
		if err := rows.Err(); err != nil {
			_ = rows.Close()
			return err
		}
		if err := rows.Close(); err != nil {
			return err
		}
		if !hasKind {
			if _, err := db.Exec("ALTER TABLE " + table + " ADD COLUMN kind TEXT NOT NULL DEFAULT 'file'"); err != nil {
				return err
			}
		}
	}
	return nil
}
