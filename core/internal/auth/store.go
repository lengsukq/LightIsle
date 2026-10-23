package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"golang.org/x/crypto/argon2"
)

var (
	ErrExists    = errors.New("account already exists")
	ErrInvalid   = errors.New("invalid username or password")
	ErrInput     = errors.New("invalid account data")
	ErrForbidden = errors.New("forbidden operation")
	ErrNotFound  = errors.New("account not found")
	userRule     = regexp.MustCompile(`^[A-Za-z0-9_.-]{3,32}$`)
)

type Store struct {
	db *sql.DB
	// afterVerify lets tests pause Login between the credential read and the
	// session insert to exercise concurrent credential changes.
	afterVerify func()
}

// ChangePassword requires the existing password and the caller's current
// session. Unlike the Mac owner's offline recovery, this route can be exposed
// to signed-in members. All sessions (including the requesting one) are
// revoked atomically with the credential update.
func (s *Store) ChangePassword(session, oldPassword, newPassword string) error {
	user, ok := s.Identity(session)
	if !ok {
		return ErrForbidden
	}
	if !Validate(user.Username, newPassword) || oldPassword == newPassword {
		return ErrInput
	}
	var salt, expected []byte
	var enabled int
	err := s.db.QueryRow("SELECT salt,password_hash,enabled FROM users WHERE id=?", user.ID).
		Scan(&salt, &expected, &enabled)
	if err != nil {
		return err
	}
	actual := derive(oldPassword, salt)
	if enabled != 1 || subtle.ConstantTimeCompare(actual, expected) != 1 {
		return ErrInvalid
	}
	newSalt, err := random(16)
	if err != nil {
		return err
	}
	newHash := derive(newPassword, newSalt)
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// Compare against the verified previous hash so concurrent resets, account
	// disables, or other password updates cannot be silently overwritten.
	result, err := tx.Exec("UPDATE users SET salt=?,password_hash=? WHERE id=? AND salt=? AND password_hash=? AND enabled=1",
		newSalt, newHash, user.ID, salt, expected)
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected != 1 {
		return ErrInvalid
	}
	if _, err := tx.Exec("DELETE FROM sessions WHERE user_id=?", user.ID); err != nil {
		return err
	}
	return tx.Commit()
}

type User struct {
	ID        int64  `json:"id"`
	Username  string `json:"username"`
	Role      string `json:"role"`
	Enabled   bool   `json:"enabled"`
	CreatedAt int64  `json:"createdAt"`
}

// ResetFirstAdminPassword is exclusively used by the macOS native-owner
// recovery flow after LocalAuthentication has approved Touch ID or the Mac
// login password. Never register this method on an HTTP route.
// Existing Web sessions for the recovered administrator are invalidated.
// Return the recovered account username so macOS can show which login to use.
func (s *Store) ResetFirstAdminPassword(password string) (string, error) {
	var id int64
	var username string
	var enabled int
	err := s.db.QueryRow("SELECT id,username,enabled FROM users WHERE role=? ORDER BY id LIMIT 1", RoleAdmin).
		Scan(&id, &username, &enabled)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if enabled != 1 {
		return "", ErrNotFound
	}
	if !Validate(username, password) {
		return "", ErrInput
	}
	salt, err := random(16)
	if err != nil {
		return "", err
	}
	hash := derive(password, salt)
	tx, err := s.db.Begin()
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	result, err := tx.Exec("UPDATE users SET salt=?,password_hash=? WHERE id=? AND role=? AND enabled=1", salt, hash, id, RoleAdmin)
	if err != nil {
		return "", err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return "", err
	}
	if affected != 1 {
		return "", ErrNotFound
	}
	if _, err := tx.Exec("DELETE FROM sessions WHERE user_id=?", id); err != nil {
		return "", err
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	return username, nil
}

const (
	RoleAdmin  = "admin"
	RoleMember = "member"

	SessionLifetime = 30 * 24 * time.Hour
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
		`CREATE TABLE IF NOT EXISTS file_grants (
		user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		path TEXT NOT NULL, can_write INTEGER NOT NULL CHECK(can_write IN (0,1)),
		PRIMARY KEY(user_id,path))`,
	}
	for _, q := range stmts {
		if _, err := db.Exec(q); err != nil {
			_ = db.Close()
			return nil, fmt.Errorf("init SQLite: %w", err)
		}
	}
	return &Store{db: db}, nil
}
func (s *Store) Close() error { return s.db.Close() }
func (s *Store) FirstAdminUsername() (string, error) {
	var username string
	err := s.db.QueryRow("SELECT username FROM users WHERE role=? ORDER BY id LIMIT 1", RoleAdmin).Scan(&username)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return username, err
}
func (s *Store) Configured() (bool, error) {
	var count int
	err := s.db.QueryRow("SELECT COUNT(*) FROM users").Scan(&count)
	return count > 0, err
}
func Validate(username, password string) bool {
	return userRule.MatchString(username) && len(password) >= 12 && len(password) <= 256 &&
		strings.TrimSpace(password) == password
}
func random(n int) ([]byte, error) { b := make([]byte, n); _, err := rand.Read(b); return b, err }
func derive(password string, salt []byte) []byte {
	return argon2.IDKey([]byte(password), salt, 3, 64*1024, 2, 32)
}

func (s *Store) Setup(username, password string) error {
	if !Validate(username, password) {
		return ErrInput
	}
	salt, err := random(16)
	if err != nil {
		return err
	}
	hash := derive(password, salt)
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var count int
	if err := tx.QueryRow("SELECT COUNT(*) FROM users").Scan(&count); err != nil {
		return err
	}
	if count > 0 {
		return ErrExists
	}
	_, err = tx.Exec("INSERT INTO users(username,role,enabled,salt,password_hash,created_at) VALUES(?,?,?,?,?,?)",
		username, RoleAdmin, 1, salt, hash, time.Now().Unix())
	if err != nil {
		return err
	}
	return tx.Commit()
}
func (s *Store) CreateUser(actorToken, username, password, role string) (User, error) {
	actor, ok := s.Identity(actorToken)
	if !ok || actor.Role != RoleAdmin {
		return User{}, ErrForbidden
	}
	if !Validate(username, password) || (role != RoleAdmin && role != RoleMember) {
		return User{}, ErrInput
	}
	salt, err := random(16)
	if err != nil {
		return User{}, err
	}
	hash := derive(password, salt)
	res, err := s.db.Exec("INSERT INTO users(username,role,enabled,salt,password_hash,created_at) VALUES(?,?,?,?,?,?)",
		username, role, 1, salt, hash, time.Now().Unix())
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "unique") {
			return User{}, ErrExists
		}
		return User{}, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return User{}, err
	}
	return s.GetUser(id)
}
func (s *Store) GetUser(id int64) (User, error) {
	var u User
	var enabled int
	err := s.db.QueryRow("SELECT id,username,role,enabled,created_at FROM users WHERE id=?", id).
		Scan(&u.ID, &u.Username, &u.Role, &enabled, &u.CreatedAt)
	u.Enabled = enabled == 1
	if err == sql.ErrNoRows {
		return User{}, ErrNotFound
	}
	return u, err
}
func (s *Store) ListUsers(actorToken string) ([]User, error) {
	actor, ok := s.Identity(actorToken)
	if !ok || actor.Role != RoleAdmin {
		return nil, ErrForbidden
	}
	rows, err := s.db.Query("SELECT id,username,role,enabled,created_at FROM users ORDER BY id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list := []User{}
	for rows.Next() {
		var u User
		var enabled int
		if err := rows.Scan(&u.ID, &u.Username, &u.Role, &enabled, &u.CreatedAt); err != nil {
			return nil, err
		}
		u.Enabled = enabled == 1
		list = append(list, u)
	}
	return list, rows.Err()
}
func (s *Store) SetEnabled(actorToken string, id int64, enabled bool) error {
	actor, ok := s.Identity(actorToken)
	if !ok || actor.Role != RoleAdmin {
		return ErrForbidden
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var firstAdminID int64
	if err := tx.QueryRow("SELECT id FROM users WHERE role=? ORDER BY id LIMIT 1", RoleAdmin).Scan(&firstAdminID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	if !enabled && (id == firstAdminID || id == actor.ID) {
		return ErrForbidden
	}
	value := 0
	if enabled {
		value = 1
	}
	result, err := tx.Exec("UPDATE users SET enabled=? WHERE id=?", value, id)
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected != 1 {
		return ErrNotFound
	}
	if !enabled {
		if _, err := tx.Exec("DELETE FROM sessions WHERE user_id=?", id); err != nil {
			return err
		}
	}
	return tx.Commit()
}
func (s *Store) Login(username, password string) (string, error) {
	var id int64
	var salt, expected []byte
	var enabled int
	err := s.db.QueryRow("SELECT id,salt,password_hash,enabled FROM users WHERE username=?", username).
		Scan(&id, &salt, &expected, &enabled)
	if err != nil && err != sql.ErrNoRows {
		return "", err
	}
	// Unknown users still consume an Argon2id derivation.
	if err == sql.ErrNoRows {
		salt = make([]byte, 16)
		expected = make([]byte, 32)
	}
	actual := derive(password, salt)
	if err != nil || enabled != 1 || subtle.ConstantTimeCompare(actual, expected) != 1 {
		return "", ErrInvalid
	}
	if s.afterVerify != nil {
		s.afterVerify()
	}
	bytes, err := random(32)
	if err != nil {
		return "", err
	}
	token := base64.RawURLEncoding.EncodeToString(bytes)
	digest := sha256.Sum256([]byte(token))
	now := time.Now().Unix()
	// The session insert only succeeds while the credentials that were just
	// verified are still current, so a concurrent password reset or disable
	// cannot leave behind a usable session created from the stale read.
	result, err := s.db.Exec(`INSERT INTO sessions(id,user_id,expires_at,created_at)
		SELECT ?,id,?,? FROM users WHERE id=? AND salt=? AND password_hash=? AND enabled=1`,
		digest[:], now+int64(SessionLifetime.Seconds()), now, id, salt, expected)
	if err != nil {
		return "", err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return "", err
	}
	if affected != 1 {
		return "", ErrInvalid
	}
	return token, nil
}
func (s *Store) Identity(token string) (User, bool) {
	if len(token) < 30 || len(token) > 128 {
		return User{}, false
	}
	digest := sha256.Sum256([]byte(token))
	var u User
	var enabled int
	err := s.db.QueryRow(`SELECT u.id,u.username,u.role,u.enabled,u.created_at
		FROM sessions s JOIN users u ON u.id=s.user_id
		WHERE s.id=? AND s.expires_at>?`, digest[:], time.Now().Unix()).
		Scan(&u.ID, &u.Username, &u.Role, &enabled, &u.CreatedAt)
	u.Enabled = enabled == 1
	return u, err == nil && u.Enabled
}
func (s *Store) Session(token string) bool { _, ok := s.Identity(token); return ok }
func (s *Store) Username(token string) string {
	u, ok := s.Identity(token)
	if !ok {
		return ""
	}
	return u.Username
}
func (s *Store) Logout(token string) {
	digest := sha256.Sum256([]byte(token))
	_, _ = s.db.Exec("DELETE FROM sessions WHERE id=?", digest[:])
}
