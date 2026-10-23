package auth

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"time"
)

// CreateRootFileShare publishes a root- and generation-bound bearer link.
// expiresAt is an absolute Unix timestamp; only its digest is persisted.
// Authorization is rechecked in the INSERT transaction so a concurrent
// grant/session revoke cannot leave a dormant link that becomes valid after a
// later regrant.
func (s *Store) CreateRootFileShare(ctx context.Context, session, rootID string, rootGeneration uint64, name, fingerprint string, expiresAt int64) (FileShare, string, error) {
	if ctx == nil || !validRootID(rootID) || rootGeneration == 0 || rootGeneration > uint64(1<<63-1) || !validGrantPath(name) || name == "." ||
		fingerprint == "" || len(fingerprint) > 1024 {
		return FileShare{}, "", ErrInput
	}
	now := time.Now().Unix()
	if expiresAt <= now || expiresAt > now+int64(MaxShareHours)*3600 {
		return FileShare{}, "", ErrInput
	}
	user, ok := s.Identity(session)
	if !ok || !s.CanAccessRoot(session, rootID, name, false, false) {
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
	sessionID := sha256.Sum256([]byte(session))
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return FileShare{}, "", err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, "DELETE FROM file_shares WHERE expires_at<=?", now); err != nil {
		return FileShare{}, "", err
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM root_file_shares WHERE expires_at<=?", now); err != nil {
		return FileShare{}, "", err
	}
	var count int
	if err := tx.QueryRowContext(ctx, `SELECT
		(SELECT COUNT(*) FROM file_shares WHERE user_id=? AND expires_at>?) +
		(SELECT COUNT(*) FROM root_file_shares WHERE user_id=? AND expires_at>?)`,
		user.ID, now, user.ID, now).Scan(&count); err != nil {
		return FileShare{}, "", err
	}
	if count >= MaxFileShares {
		return FileShare{}, "", ErrExists
	}
	result, err := tx.ExecContext(ctx, `INSERT INTO root_file_shares
		(id,user_id,root_id,root_generation,file_path,file_identity,created_at,expires_at)
		SELECT ?,u.id,?,?,?,?,?,? FROM users u JOIN sessions ss ON ss.user_id=u.id
		WHERE u.id=? AND u.enabled=1 AND ss.id=? AND ss.expires_at>?
		AND (u.role=? OR EXISTS(SELECT 1 FROM root_file_grants g
			WHERE g.user_id=u.id AND g.root_id=?
			AND (g.path='.' OR g.path=? OR substr(?,1,length(g.path)+1)=g.path||'/')))`,
		digest[:], rootID, int64(rootGeneration), name, fingerprint, now, expiresAt, user.ID, sessionID[:], time.Now().Unix(), RoleAdmin, rootID, name, name)
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
	return FileShare{ID: hex.EncodeToString(digest[:]), RootID: rootID, RootGeneration: rootGeneration, Path: name, CreatedAt: now, ExpiresAt: expiresAt}, token, nil
}

func (s *Store) ListRootFileShares(session, rootID string) ([]FileShare, error) {
	if !validRootID(rootID) {
		return nil, ErrInput
	}
	user, ok := s.Identity(session)
	if !ok {
		return nil, ErrForbidden
	}
	sessionID := sha256.Sum256([]byte(session))
	rows, err := s.db.Query(`SELECT id,file_path,created_at,expires_at,root_generation FROM root_file_shares
		WHERE user_id=? AND root_id=? AND expires_at>? AND EXISTS(
			SELECT 1 FROM sessions ss JOIN users u ON u.id=ss.user_id
			WHERE ss.id=? AND ss.user_id=? AND ss.expires_at>? AND u.enabled=1)
		ORDER BY created_at DESC LIMIT 100`,
		user.ID, rootID, time.Now().Unix(), sessionID[:], user.ID, time.Now().Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]FileShare, 0, 8)
	for rows.Next() {
		var digest []byte
		var item FileShare
		if err := rows.Scan(&digest, &item.Path, &item.CreatedAt, &item.ExpiresAt, &item.RootGeneration); err != nil {
			return nil, err
		}
		if len(digest) != sha256.Size {
			return nil, ErrInput
		}
		item.ID = hex.EncodeToString(digest)
		item.RootID = rootID
		result = append(result, item)
	}
	return result, rows.Err()
}

// RevokeRootFileShare removes only a link owned by this account and scoped to
// the named root. A missing or foreign share is a harmless no-op.
func (s *Store) RevokeRootFileShare(ctx context.Context, session, rootID, shareID string) error {
	if ctx == nil || !validRootID(rootID) || len(shareID) != sha256.Size*2 {
		return ErrInput
	}
	digest, err := hex.DecodeString(shareID)
	if err != nil {
		return ErrInput
	}
	user, ok := s.Identity(session)
	if !ok {
		return ErrForbidden
	}
	sessionID := sha256.Sum256([]byte(session))
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(ctx, `DELETE FROM root_file_shares
		WHERE id=? AND user_id=? AND root_id=? AND EXISTS(
			SELECT 1 FROM sessions ss JOIN users u ON u.id=ss.user_id
			WHERE ss.id=? AND ss.user_id=? AND ss.expires_at>? AND u.enabled=1)`,
		digest, user.ID, rootID, sessionID[:], user.ID, time.Now().Unix())
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) ResolveRootFileShare(token string) (ShareAccess, error) {
	var item ShareAccess
	if len(token) != 43 {
		return item, ErrNotFound
	}
	secret, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(secret) != 32 {
		return item, ErrNotFound
	}
	digest := sha256.Sum256([]byte(token))
	err = s.db.QueryRow(`SELECT shares.user_id,shares.root_id,shares.root_generation,shares.file_path,shares.file_identity
		FROM root_file_shares shares JOIN users u ON u.id=shares.user_id
		WHERE shares.id=? AND shares.expires_at>? AND u.enabled=1
		AND (u.role=? OR EXISTS(SELECT 1 FROM root_file_grants g
			WHERE g.user_id=u.id AND g.root_id=shares.root_id
			AND (g.path='.' OR g.path=shares.file_path
				OR substr(shares.file_path,1,length(g.path)+1)=g.path||'/')))`,
		digest[:], time.Now().Unix(), RoleAdmin).
		Scan(&item.UserID, &item.RootID, &item.RootGeneration, &item.Path, &item.Identity)
	if errors.Is(err, sql.ErrNoRows) || err == nil && (!validRootID(item.RootID) || item.RootGeneration == 0) {
		return ShareAccess{}, ErrNotFound
	}
	return item, err
}
