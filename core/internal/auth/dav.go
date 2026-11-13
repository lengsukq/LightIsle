package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
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
	Revision   string `json:"revision,omitempty"`
}

// A one-way non-secret tag helps local Keychains detect rotation elsewhere.
func davRevision(digest []byte) string {
	sum := sha256.Sum256(digest)
	return hex.EncodeToString(sum[:12])
}

// VerifyDAVCredential resolves a Basic-auth username/password pair to an
// enabled account. Failures never reveal whether the username exists.
func (s *Store) VerifyDAVCredential(username, password string) (User, error) {
	if username == "" || password == "" {
		return User{}, ErrForbidden
	}
	rdb := s.readDB()
	var user User
	err := rdb.QueryRow(
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
	rows, err := rdb.Query("SELECT id,digest,last_used_at FROM dav_credentials WHERE user_id=?", user.ID)
	if err != nil {
		return User{}, err
	}
	matched := int64(0)
	matchedLastUsed := int64(0)
	for rows.Next() {
		var id, lastUsed int64
		var stored []byte
		if err := rows.Scan(&id, &stored, &lastUsed); err != nil {
			_ = rows.Close()
			return User{}, err
		}
		if subtle.ConstantTimeCompare(digest[:], stored) == 1 {
			matched = id
			matchedLastUsed = lastUsed
		}
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return User{}, err
	}
	_ = rows.Close()
	if matched == 0 {
		return User{}, ErrForbidden
	}
	now := time.Now().Unix()
	if matchedLastUsed < now-davLastUsedGranularity {
		if _, err := s.db.Exec(
			"UPDATE dav_credentials SET last_used_at=? WHERE id=? AND last_used_at<?",
			now, matched, now-davLastUsedGranularity,
		); err != nil {
			return User{}, err
		}
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
	return DAVCredential{ID: id, Label: label, CreatedAt: now, Revision: davRevision(digest[:])}, password, nil
}

// RotateDAVCredential replaces the stored digest in place and returns the
// newly generated secret once. The former password immediately stops working,
// and neither old nor new secrets can be retrieved from the database.
func (s *Store) RotateDAVCredential(session string, id int64) (string, error) {
	actor, ok := s.Identity(session)
	if !ok {
		return "", ErrForbidden
	}
	if id <= 0 {
		return "", ErrInput
	}
	raw := make([]byte, davPasswordBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	password := base64.RawURLEncoding.EncodeToString(raw)
	digest := sha256.Sum256([]byte(password))
	result, err := s.db.Exec(
		"UPDATE dav_credentials SET digest=?, last_used_at=0 WHERE id=? AND user_id=?",
		digest[:], id, actor.ID,
	)
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
	return password, nil
}

func (s *Store) ListDAVCredentials(session string) ([]DAVCredential, error) {
	actor, ok := s.Identity(session)
	if !ok {
		return nil, ErrForbidden
	}
	rows, err := s.readDB().Query(
		"SELECT id,label,created_at,last_used_at,digest FROM dav_credentials WHERE user_id=? ORDER BY id", actor.ID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []DAVCredential{}
	for rows.Next() {
		var c DAVCredential
		var digest []byte
		if err := rows.Scan(&c.ID, &c.Label, &c.CreatedAt, &c.LastUsedAt, &digest); err != nil {
			return nil, err
		}
		c.Revision = davRevision(digest)
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
