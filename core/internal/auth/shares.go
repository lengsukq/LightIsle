package auth

import (
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"time"
)

const (
	MaxFileShares = 100
	MaxShareHours = 168
)

type FileShare struct {
	ID             string `json:"id"`
	Path           string `json:"path"`
	RootID         string `json:"rootId,omitempty"`
	RootGeneration uint64 `json:"rootGeneration,omitempty"`
	CreatedAt      int64  `json:"createdAt"`
	ExpiresAt      int64  `json:"expiresAt"`
}

type ShareAccess struct {
	UserID         int64
	RootID         string
	RootGeneration uint64
	Path           string
	Identity       string
}

// CreateFileShare issues a high-entropy one-time capability. Only the digest
// is persisted; the bearer token cannot be reconstructed from the database.
func (s *Store) CreateFileShare(session, name, identity string, hours int) (FileShare, string, error) {
	if !validGrantPath(name) || name == "." || identity == "" || hours < 1 || hours > MaxShareHours {
		return FileShare{}, "", ErrInput
	}
	user, ok := s.Identity(session)
	if !ok || !s.CanAccess(session, name, false, false) {
		return FileShare{}, "", ErrForbidden
	}
	if s.afterShareAuthorization != nil {
		s.afterShareAuthorization()
	}
	secret, err := random(32)
	if err != nil {
		return FileShare{}, "", err
	}
	token := base64.RawURLEncoding.EncodeToString(secret)
	digest := sha256.Sum256([]byte(token))
	now := time.Now().Unix()
	tx, err := s.db.Begin()
	if err != nil {
		return FileShare{}, "", err
	}
	defer tx.Rollback()
	if _, err := tx.Exec("DELETE FROM file_shares WHERE expires_at<=?", now); err != nil {
		return FileShare{}, "", err
	}
	if _, err := tx.Exec("DELETE FROM root_file_shares WHERE expires_at<=?", now); err != nil {
		return FileShare{}, "", err
	}
	var count int
	if err := tx.QueryRow(`SELECT
		(SELECT COUNT(*) FROM file_shares WHERE user_id=? AND expires_at>?) +
		(SELECT COUNT(*) FROM root_file_shares WHERE user_id=? AND expires_at>?)`, user.ID, now, user.ID, now).Scan(&count); err != nil {
		return FileShare{}, "", err
	}
	if count >= MaxFileShares {
		return FileShare{}, "", ErrExists
	}
	// Publish against the same database transaction as the final session and
	// grant check. Otherwise a concurrent grant removal can delete all links
	// before this INSERT, leaving a stale capability that revives on regrant.
	sessionDigest := sha256.Sum256([]byte(session))
	result, err := tx.Exec(`INSERT INTO file_shares(id,user_id,file_path,file_identity,created_at,expires_at)
		SELECT ?,u.id,?,?,?,? FROM users u JOIN sessions ss ON ss.user_id=u.id
		WHERE u.id=? AND u.enabled=1 AND ss.id=? AND ss.expires_at>?
		AND (u.role=? OR EXISTS(SELECT 1 FROM file_grants fg WHERE fg.user_id=u.id
		AND (fg.path='.' OR fg.path=? OR substr(?,1,length(fg.path)+1)=fg.path||'/')))`,
		digest[:], name, identity, now, now+int64(hours)*3600, user.ID, sessionDigest[:], time.Now().Unix(), RoleAdmin, name, name)
	if err != nil {
		return FileShare{}, "", err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return FileShare{}, "", err
	}
	if affected != 1 {
		return FileShare{}, "", ErrForbidden
	}
	if err := tx.Commit(); err != nil {
		return FileShare{}, "", err
	}
	return FileShare{ID: hex.EncodeToString(digest[:]), Path: name, CreatedAt: now, ExpiresAt: now + int64(hours)*3600}, token, nil
}

func (s *Store) ListFileShares(session string) ([]FileShare, error) {
	user, ok := s.Identity(session)
	if !ok {
		return nil, ErrForbidden
	}
	rows, err := s.db.Query(`SELECT id,file_path,created_at,expires_at FROM file_shares
		WHERE user_id=? AND expires_at>? ORDER BY created_at DESC LIMIT 100`, user.ID, time.Now().Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]FileShare, 0, 8)
	for rows.Next() {
		var digest []byte
		var item FileShare
		if err := rows.Scan(&digest, &item.Path, &item.CreatedAt, &item.ExpiresAt); err != nil {
			return nil, err
		}
		if len(digest) != sha256.Size {
			return nil, ErrInput
		}
		item.ID = hex.EncodeToString(digest)
		result = append(result, item)
	}
	return result, rows.Err()
}

// RevokeFileShare never revokes another account's capability.
func (s *Store) RevokeFileShare(session, shareID string) error {
	user, ok := s.Identity(session)
	if !ok {
		return ErrForbidden
	}
	if len(shareID) != 64 {
		return ErrInput
	}
	digest, err := hex.DecodeString(shareID)
	if err != nil {
		return ErrInput
	}
	_, err = s.db.Exec("DELETE FROM file_shares WHERE id=? AND user_id=?", digest, user.ID)
	return err
}

func (s *Store) ResolveFileShare(token string) (ShareAccess, error) {
	var item ShareAccess
	if len(token) != 43 {
		return item, ErrNotFound
	}
	if _, err := base64.RawURLEncoding.DecodeString(token); err != nil {
		return item, ErrNotFound
	}
	digest := sha256.Sum256([]byte(token))
	err := s.db.QueryRow(`SELECT shares.user_id,shares.file_path,shares.file_identity FROM file_shares shares
		JOIN users u ON u.id=shares.user_id
		WHERE shares.id=? AND shares.expires_at>? AND u.enabled=1`, digest[:], time.Now().Unix()).
		Scan(&item.UserID, &item.Path, &item.Identity)
	if errors.Is(err, sql.ErrNoRows) {
		return ShareAccess{}, ErrNotFound
	}
	return item, err
}

// UserCanRead is evaluated for every bearer-link request so revoking a
// directory grant, disabling the member or removing a link takes effect.
func (s *Store) UserCanRead(id int64, name string) bool {
	if id <= 0 || !validGrantPath(name) {
		return false
	}
	user, err := s.GetUser(id)
	if err != nil || !user.Enabled {
		return false
	}
	if user.Role == RoleAdmin {
		return true
	}
	grants, err := s.grants(id)
	if err != nil {
		return false
	}
	for _, grant := range grants {
		if grant.Path == "." || name == grant.Path || len(name) > len(grant.Path) && name[:len(grant.Path)+1] == grant.Path+"/" {
			return true
		}
	}
	return false
}
