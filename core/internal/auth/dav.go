package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"errors"
	"time"
)

// WebDAV credentials are deliberately independent from web sessions: they
// never reuse the session cookie, are generated server-side, shown exactly
// once and stored only as a SHA-256 digest (share-token discipline). Basic
// auth verification runs per request, so the fast digest comparison is used
// instead of Argon2id; the password carries 144 bits of entropy.
const (
	MaxDAVCredentialsPerUser = 8
	davPasswordBytes         = 18
	davLastUsedGranularity   = int64(60) // seconds between last_used_at updates
)

var ErrDAVCredentialLimit = errors.New("dav_credential_limit_reached")

type DAVCredential struct {
	ID         int64  `json:"id"`
	Label      string `json:"label"`
	CreatedAt  int64  `json:"createdAt"`
	LastUsedAt int64  `json:"lastUsedAt"`
}

// VerifyDAVCredential resolves a Basic-auth username/password pair to an
// enabled account. Failures never reveal whether the username exists.
func (s *Store) VerifyDAVCredential(username, password string) (User, error) {
	if username == "" || password == "" {
		return User{}, ErrForbidden
	}
	var user User
	err := s.db.QueryRow(
		"SELECT id,username,role,enabled FROM users WHERE username=? COLLATE NOCASE", username,
	).Scan(&user.ID, &user.Username, &user.Role, &user.Enabled)
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, ErrForbidden
	}
	if err != nil {
		return User{}, err
	}
	if !user.Enabled {
		return User{}, ErrForbidden
	}
	digest := sha256.Sum256([]byte(password))
	rows, err := s.db.Query("SELECT id,digest FROM dav_credentials WHERE user_id=?", user.ID)
	if err != nil {
		return User{}, err
	}
	defer rows.Close()
	matched := int64(0)
	for rows.Next() {
		var id int64
		var stored []byte
		if err := rows.Scan(&id, &stored); err != nil {
			return User{}, err
		}
		if subtle.ConstantTimeCompare(digest[:], stored) == 1 {
			matched = id
		}
	}
	if err := rows.Err(); err != nil {
		return User{}, err
	}
	if matched == 0 {
		return User{}, ErrForbidden
	}
	if _, err := s.db.Exec(
		"UPDATE dav_credentials SET last_used_at=? WHERE id=? AND last_used_at<?",
		time.Now().Unix(), matched, time.Now().Unix()-davLastUsedGranularity,
	); err != nil {
		return User{}, err
	}
	return user, nil
}

// CreateDAVCredential generates a new password for the signed-in account and
// returns the credential row plus the plaintext password exactly once.
func (s *Store) CreateDAVCredential(session, label string) (DAVCredential, string, error) {
	actor, ok := s.Identity(session)
	if !ok {
		return DAVCredential{}, "", ErrForbidden
	}
	if len(label) > 64 {
		return DAVCredential{}, "", ErrInput
	}
	raw := make([]byte, davPasswordBytes)
	if _, err := rand.Read(raw); err != nil {
		return DAVCredential{}, "", err
	}
	password := base64.RawURLEncoding.EncodeToString(raw)
	digest := sha256.Sum256([]byte(password))
	var existing int
	if err := s.db.QueryRow("SELECT COUNT(*) FROM dav_credentials WHERE user_id=?", actor.ID).Scan(&existing); err != nil {
		return DAVCredential{}, "", err
	}
	if existing >= MaxDAVCredentialsPerUser {
		return DAVCredential{}, "", ErrDAVCredentialLimit
	}
	now := time.Now().Unix()
	result, err := s.db.Exec(
		"INSERT INTO dav_credentials(user_id,label,digest,created_at,last_used_at) VALUES(?,?,?,?,0)",
		actor.ID, label, digest[:], now,
	)
	if err != nil {
		return DAVCredential{}, "", err
	}
	id, err := result.LastInsertId()
	if err != nil {
		return DAVCredential{}, "", err
	}
	return DAVCredential{ID: id, Label: label, CreatedAt: now}, password, nil
}

func (s *Store) ListDAVCredentials(session string) ([]DAVCredential, error) {
	actor, ok := s.Identity(session)
	if !ok {
		return nil, ErrForbidden
	}
	rows, err := s.db.Query(
		"SELECT id,label,created_at,last_used_at FROM dav_credentials WHERE user_id=? ORDER BY id", actor.ID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []DAVCredential{}
	for rows.Next() {
		var c DAVCredential
		if err := rows.Scan(&c.ID, &c.Label, &c.CreatedAt, &c.LastUsedAt); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// RevokeDAVCredential permanently invalidates one of the caller's own
// credentials. Members may only manage their own credentials.
func (s *Store) RevokeDAVCredential(session string, id int64) error {
	actor, ok := s.Identity(session)
	if !ok {
		return ErrForbidden
	}
	result, err := s.db.Exec("DELETE FROM dav_credentials WHERE id=? AND user_id=?", id, actor.ID)
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected == 0 {
		return ErrNotFound
	}
	return nil
}
