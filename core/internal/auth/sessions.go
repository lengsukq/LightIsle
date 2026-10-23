package auth

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"time"
)

// AccountSession is a non-secret session descriptor. Its ID is the digest
// stored in SQLite; it is NOT the bearer cookie and cannot authenticate.
type AccountSession struct {
	ID        string `json:"id"`
	CreatedAt int64  `json:"createdAt"`
	ExpiresAt int64  `json:"expiresAt"`
	Current   bool   `json:"current"`
}

// ListSessions returns only the authenticated user's live sessions.
// Large inventories are bounded so a damaged or abusive session table cannot
// result in an unbounded response.
func (s *Store) ListSessions(token string) ([]AccountSession, bool, error) {
	user, ok := s.Identity(token)
	if !ok {
		return nil, false, ErrForbidden
	}
	current := sha256.Sum256([]byte(token))
	rows, err := s.db.Query(`SELECT id,created_at,expires_at FROM sessions
		WHERE user_id=? AND expires_at>? ORDER BY created_at DESC, rowid DESC LIMIT 101`,
		user.ID, time.Now().Unix())
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	result := make([]AccountSession, 0, 8)
	truncated := false
	for rows.Next() {
		var digest []byte
		var item AccountSession
		if err := rows.Scan(&digest, &item.CreatedAt, &item.ExpiresAt); err != nil {
			return nil, false, err
		}
		if len(digest) != sha256.Size {
			return nil, false, errors.New("invalid_session_digest")
		}
		if len(result) == 100 {
			truncated = true
			break
		}
		item.ID = hex.EncodeToString(digest)
		item.Current = string(digest) == string(current[:])
		result = append(result, item)
	}
	return result, truncated, rows.Err()
}

// RevokeSession cannot affect sessions owned by a different account.
func (s *Store) RevokeSession(token, sessionID string) (bool, error) {
	user, ok := s.Identity(token)
	if !ok {
		return false, ErrForbidden
	}
	if len(sessionID) != sha256.Size*2 {
		return false, ErrInput
	}
	digest, err := hex.DecodeString(sessionID)
	if err != nil {
		return false, ErrInput
	}
	_, err = s.db.Exec("DELETE FROM sessions WHERE id=? AND user_id=?", digest, user.ID)
	if err != nil {
		return false, err
	}
	current := sha256.Sum256([]byte(token))
	return string(digest) == string(current[:]), nil
}

// RevokeOtherSessions keeps the caller online while removing all other
// devices' sessions. Changing the password is the separate all-device action.
func (s *Store) RevokeOtherSessions(token string) (int64, error) {
	user, ok := s.Identity(token)
	if !ok {
		return 0, ErrForbidden
	}
	digest := sha256.Sum256([]byte(token))
	result, err := s.db.Exec("DELETE FROM sessions WHERE user_id=? AND id<>?", user.ID, digest[:])
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}
