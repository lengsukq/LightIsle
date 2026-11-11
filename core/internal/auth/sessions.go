package auth

import (
	"crypto/sha256"
	"database/sql"
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
		WHERE user_id=? AND expires_at>? AND id NOT IN (SELECT session_id FROM mcp_connections)
		ORDER BY created_at DESC, rowid DESC LIMIT 101`,
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
	if len(sessionID) != sha256.Size*2 {
		return false, ErrInput
	}
	target, err := hex.DecodeString(sessionID)
	if err != nil {
		return false, ErrInput
	}
	current := sha256.Sum256([]byte(token))
	_, err = s.revokeSessions(current, target)
	return err == nil && string(target) == string(current[:]), err
}

// RevokeOtherSessions keeps the caller online while removing all other
// devices' sessions. Changing the password is the separate all-device action.
func (s *Store) RevokeOtherSessions(token string) (int64, error) {
	return s.revokeSessions(sha256.Sum256([]byte(token)), nil)
}

func (s *Store) revokeSessions(current [sha256.Size]byte, target []byte) (int64, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var userID int64
	err = tx.QueryRow(`SELECT s.user_id FROM sessions s JOIN users u ON u.id=s.user_id
		WHERE s.id=? AND s.expires_at>? AND u.enabled=1`, current[:], time.Now().Unix()).Scan(&userID)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrForbidden
	}
	if err != nil {
		return 0, err
	}
	var result sql.Result
	if target == nil {
		result, err = tx.Exec(`DELETE FROM sessions WHERE user_id=? AND id<>?
			AND id NOT IN (SELECT session_id FROM mcp_connections)`, userID, current[:])
	} else {
		result, err = tx.Exec(`DELETE FROM sessions WHERE user_id=? AND id=?
			AND id NOT IN (SELECT session_id FROM mcp_connections)`, userID, target)
	}
	if err != nil {
		return 0, err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return count, nil
}

func adminSessionValidTx(tx *sql.Tx, session string, userID int64) (bool, error) {
	if tx == nil || session == "" || userID <= 0 {
		return false, nil
	}
	var one int
	digest := sha256.Sum256([]byte(session))
	err := tx.QueryRow(`SELECT 1 FROM sessions ss JOIN users u ON u.id=ss.user_id
		WHERE ss.id=? AND ss.user_id=? AND ss.expires_at>? AND u.enabled=1 AND u.role=?`,
		digest[:], userID, time.Now().Unix(), RoleAdmin).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// PruneExpired deletes expired sessions and expired rows in both share
// tables in one transaction. Sessions previously only shrank on explicit
// logout, revocation or account disable, and expired shares were only swept
// lazily when someone created the next share; the periodic monitor calls
// this so the tables stay bounded over long uptimes.
func (s *Store) PruneExpired(now time.Time) error {
	at := now.Unix()
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, stmt := range []string{
		"DELETE FROM sessions WHERE expires_at<=?",
		"DELETE FROM file_shares WHERE expires_at<=?",
		"DELETE FROM root_file_shares WHERE expires_at<=?",
	} {
		if _, err := tx.Exec(stmt, at); err != nil {
			return err
		}
	}
	return tx.Commit()
}
