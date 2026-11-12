package auth

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"strings"
	"sync"
	"time"
)

// AccountSession is a non-secret session descriptor. Its ID is the digest
// stored in SQLite; it is NOT the bearer cookie and cannot authenticate.
type AccountSession struct {
	ID          string `json:"id"`
	CreatedAt   int64  `json:"createdAt"`
	ExpiresAt   int64  `json:"expiresAt"`
	LastSeenAt  int64  `json:"lastSeenAt,omitempty"`
	ClientIP    string `json:"clientIp,omitempty"`
	DeviceLabel string `json:"deviceLabel,omitempty"`
	UserAgent   string `json:"userAgent,omitempty"`
	Current     bool   `json:"current"`
}

var sessionTouchMu sync.Mutex
var sessionLastTouch = map[string]int64{}

func ensureSessionMetadataColumns(db *sql.DB) error {
	rows, err := db.Query("PRAGMA table_info(sessions)")
	if err != nil {
		return err
	}
	exists := map[string]bool{}
	for rows.Next() {
		var cid, notNull, pk int
		var name, colType string
		var dflt any
		if err := rows.Scan(&cid, &name, &colType, &notNull, &dflt, &pk); err != nil {
			rows.Close()
			return err
		}
		exists[name] = true
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	_ = rows.Close()
	for _, col := range []struct{ name, ddl string }{
		{"client_ip", "TEXT NOT NULL DEFAULT ''"},
		{"user_agent", "TEXT NOT NULL DEFAULT ''"},
		{"device_label", "TEXT NOT NULL DEFAULT ''"},
		{"last_seen_at", "INTEGER NOT NULL DEFAULT 0"},
	} {
		if exists[col.name] {
			continue
		}
		if _, err := db.Exec("ALTER TABLE sessions ADD COLUMN " + col.name + " " + col.ddl); err != nil {
			return err
		}
	}
	return nil
}

// SummarizeDeviceLabel derives a concise, family-readable device label from an
// HTTP User-Agent string without storing raw headers unboundedly.
func SummarizeDeviceLabel(ua string) string {
	trimmed := strings.TrimSpace(ua)
	if trimmed == "" {
		return "未知终端"
	}
	lower := strings.ToLower(trimmed)
	var osPart string
	switch {
	case strings.Contains(lower, "lightisle") && strings.Contains(lower, "ios"):
		return "iPhone / iPad · 轻屿客户端"
	case strings.Contains(lower, "lightisle") && strings.Contains(lower, "android"):
		return "Android · 轻屿客户端"
	case strings.Contains(lower, "lightisle") && (strings.Contains(lower, "macos") || strings.Contains(lower, "darwin")):
		return "Mac · 轻屿客户端"
	case strings.Contains(lower, "dart:io") || strings.Contains(lower, "flutter"):
		return "轻屿客户端"
	case strings.Contains(lower, "infuse"):
		return "Apple TV / iOS · Infuse"
	case strings.Contains(lower, "vidhub"):
		return "Apple TV / iOS · VidHub"
	case strings.Contains(lower, "iphone"):
		osPart = "iPhone"
	case strings.Contains(lower, "ipad"):
		osPart = "iPad"
	case strings.Contains(lower, "android") && strings.Contains(lower, "tv"):
		osPart = "Android TV"
	case strings.Contains(lower, "android"):
		osPart = "Android"
	case strings.Contains(lower, "macintosh") || strings.Contains(lower, "mac os x"):
		osPart = "Mac"
	case strings.Contains(lower, "windows"):
		osPart = "Windows"
	case strings.Contains(lower, "linux"):
		osPart = "Linux"
	default:
		osPart = "终端"
	}

	browser := "浏览器"
	switch {
	case strings.Contains(lower, "edg/"):
		browser = "Edge"
	case strings.Contains(lower, "chrome/") && !strings.Contains(lower, "edg/"):
		browser = "Chrome"
	case strings.Contains(lower, "firefox/"):
		browser = "Firefox"
	case strings.Contains(lower, "safari/") && !strings.Contains(lower, "chrome/"):
		browser = "Safari"
	}
	return osPart + " · " + browser
}

func sanitizeSessionField(v string, limit int) string {
	v = strings.TrimSpace(strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, v))
	if len(v) > limit {
		v = v[:limit]
	}
	return v
}

// TouchSession throttles last_seen_at writes to once per 5 minutes per session
// so ordinary authenticated API requests stay lock-free on the read pool.
func (s *Store) TouchSession(token string) {
	if s == nil || len(token) < 30 || len(token) > 128 {
		return
	}
	now := time.Now().Unix()
	digest := sha256.Sum256([]byte(token))
	key := hex.EncodeToString(digest[:8])
	sessionTouchMu.Lock()
	if len(sessionLastTouch) > 2048 {
		clear(sessionLastTouch)
	}
	last := sessionLastTouch[key]
	if now-last < 300 {
		sessionTouchMu.Unlock()
		return
	}
	sessionLastTouch[key] = now
	sessionTouchMu.Unlock()

	_, _ = s.db.Exec(`UPDATE sessions SET last_seen_at=? WHERE id=? AND expires_at>?`, now, digest[:], now)
}

// CheckpointPassive flushes WAL frames to accounts.sqlite during UPS power-loss
// transitions without blocking active readers.
func (s *Store) CheckpointPassive() {
	if s == nil || s.db == nil {
		return
	}
	_, _ = s.db.Exec("PRAGMA wal_checkpoint(PASSIVE)")
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
	rows, err := s.readDB().Query(`SELECT id,created_at,expires_at,last_seen_at,client_ip,device_label,user_agent FROM sessions
		WHERE user_id=? AND expires_at>? AND id NOT IN (SELECT session_id FROM mcp_connections)
		ORDER BY CASE WHEN id=? THEN 0 ELSE 1 END, COALESCE(NULLIF(last_seen_at,0), created_at) DESC, rowid DESC LIMIT 101`,
		user.ID, time.Now().Unix(), current[:])
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	result := make([]AccountSession, 0, 8)
	truncated := false
	for rows.Next() {
		var digest []byte
		var item AccountSession
		if err := rows.Scan(&digest, &item.CreatedAt, &item.ExpiresAt, &item.LastSeenAt, &item.ClientIP, &item.DeviceLabel, &item.UserAgent); err != nil {
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
		if item.LastSeenAt == 0 {
			item.LastSeenAt = item.CreatedAt
		}
		if item.DeviceLabel == "" && item.UserAgent != "" {
			item.DeviceLabel = SummarizeDeviceLabel(item.UserAgent)
		}
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
	if count > 0 {
		s.bumpAccessEpoch()
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
// tables in one transaction.
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
	if err := tx.Commit(); err != nil {
		return err
	}
	s.bumpAccessEpoch()
	return nil
}
