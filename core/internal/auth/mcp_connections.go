package auth

import (
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	mcpTokenPrefix    = "li_mcp_"
	mcpSessionPrefix  = "mcp:"
	maxMCPConnections = 10
)

var ErrMCPConnectionLimit = errors.New("mcp connection limit reached")

type MCPConnection struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	CanWrite  bool   `json:"canWrite"`
	CreatedAt int64  `json:"createdAt"`
	ExpiresAt int64  `json:"expiresAt"`
}

func IsBrowserSession(value string) bool {
	if len(value) != base64.RawURLEncoding.EncodedLen(32) {
		return false
	}
	_, err := base64.RawURLEncoding.Strict().DecodeString(value)
	return err == nil
}

func (s *Store) CreateMCPConnection(browserSession, label string, canWrite bool) (MCPConnection, string, error) {
	if !IsBrowserSession(browserSession) {
		return MCPConnection{}, "", ErrForbidden
	}
	label = strings.TrimSpace(label)
	if label == "" || strings.HasPrefix(label, "__") || utf8.RuneCountInString(label) > 60 || strings.ContainsFunc(label, unicode.IsControl) {
		return MCPConnection{}, "", ErrInput
	}
	secret, err := random(32)
	if err != nil {
		return MCPConnection{}, "", err
	}
	bearer := mcpTokenPrefix + base64.RawURLEncoding.EncodeToString(secret)
	digest := sha256.Sum256([]byte(mcpSessionPrefix + bearer))
	browserDigest := sha256.Sum256([]byte(browserSession))
	now := time.Now()
	item := MCPConnection{ID: hex.EncodeToString(digest[:]), Label: label, CanWrite: canWrite,
		CreatedAt: now.Unix(), ExpiresAt: now.Add(SessionLifetime).Unix()}
	tx, err := s.db.Begin()
	if err != nil {
		return MCPConnection{}, "", err
	}
	defer tx.Rollback()
	var ownerID int64
	err = tx.QueryRow(`SELECT u.id FROM sessions ss JOIN users u ON u.id=ss.user_id
		WHERE ss.id=? AND ss.expires_at>? AND u.enabled=1`, browserDigest[:], item.CreatedAt).Scan(&ownerID)
	if errors.Is(err, sql.ErrNoRows) {
		return MCPConnection{}, "", ErrForbidden
	}
	if err != nil {
		return MCPConnection{}, "", err
	}
	var count int
	err = tx.QueryRow(`SELECT COUNT(*) FROM mcp_connections mc JOIN sessions ss ON ss.id=mc.session_id
		WHERE ss.user_id=? AND ss.expires_at>? AND substr(mc.label,1,2)<>'__'`, ownerID, item.CreatedAt).Scan(&count)
	if err != nil {
		return MCPConnection{}, "", err
	}
	if count >= maxMCPConnections {
		return MCPConnection{}, "", ErrMCPConnectionLimit
	}
	if _, err := tx.Exec("INSERT INTO sessions(id,user_id,expires_at,created_at) VALUES(?,?,?,?)",
		digest[:], ownerID, item.ExpiresAt, item.CreatedAt); err != nil {
		return MCPConnection{}, "", err
	}
	if _, err := tx.Exec("INSERT INTO mcp_connections(session_id,label,can_write) VALUES(?,?,?)",
		digest[:], label, canWrite); err != nil {
		return MCPConnection{}, "", err
	}
	if err := tx.Commit(); err != nil {
		return MCPConnection{}, "", err
	}
	return item, bearer, nil
}

func (s *Store) ListMCPConnections(browserSession string) ([]MCPConnection, error) {
	if !IsBrowserSession(browserSession) {
		return nil, ErrForbidden
	}
	owner, ok := s.Identity(browserSession)
	if !ok {
		return nil, ErrForbidden
	}
	rows, err := s.db.Query(`SELECT ss.id,mc.label,mc.can_write,ss.created_at,ss.expires_at
		FROM mcp_connections mc JOIN sessions ss ON ss.id=mc.session_id
		WHERE ss.user_id=? AND ss.expires_at>? AND substr(mc.label,1,2)<>'__' ORDER BY ss.created_at DESC, ss.rowid DESC LIMIT ?`,
		owner.ID, time.Now().Unix(), maxMCPConnections)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []MCPConnection{}
	for rows.Next() {
		var digest []byte
		var item MCPConnection
		if err := rows.Scan(&digest, &item.Label, &item.CanWrite, &item.CreatedAt, &item.ExpiresAt); err != nil {
			return nil, err
		}
		item.ID = hex.EncodeToString(digest)
		items = append(items, item)
	}
	return items, rows.Err()
}

func (s *Store) RevokeMCPConnection(browserSession, id string) error {
	if !IsBrowserSession(browserSession) {
		return ErrForbidden
	}
	target, err := hex.DecodeString(id)
	if err != nil || len(target) != sha256.Size {
		return ErrInput
	}
	browserDigest := sha256.Sum256([]byte(browserSession))
	result, err := s.db.Exec(`DELETE FROM sessions WHERE id=?
		AND EXISTS(SELECT 1 FROM mcp_connections WHERE session_id=sessions.id)
		AND user_id=(SELECT u.id FROM sessions ss JOIN users u ON u.id=ss.user_id
			WHERE ss.id=? AND ss.expires_at>? AND u.enabled=1)`, target, browserDigest[:], time.Now().Unix())
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err == nil && count != 1 {
		return ErrNotFound
	}
	return err
}

// The internal session is used only by the in-process allowlisted API
// dispatcher. Neither the bearer nor this value is accepted as a Web cookie.
func (s *Store) AuthenticateMCP(bearer string) (User, string, MCPConnection, bool) {
	secret, ok := strings.CutPrefix(bearer, mcpTokenPrefix)
	if !ok || !IsBrowserSession(secret) {
		return User{}, "", MCPConnection{}, false
	}
	session := mcpSessionPrefix + bearer
	digest := sha256.Sum256([]byte(session))
	var user User
	var item MCPConnection
	err := s.db.QueryRow(`SELECT u.id,u.username,u.role,u.enabled,u.created_at,mc.label,mc.can_write
		FROM mcp_connections mc JOIN sessions ss ON ss.id=mc.session_id JOIN users u ON u.id=ss.user_id
		WHERE ss.id=? AND ss.expires_at>? AND u.enabled=1 AND substr(mc.label,1,2)<>'__'`, digest[:], time.Now().Unix()).
		Scan(&user.ID, &user.Username, &user.Role, &user.Enabled, &user.CreatedAt, &item.Label, &item.CanWrite)
	item.ID = hex.EncodeToString(digest[:])
	return user, session, item, err == nil
}

// EnsureSystemMCPSession binds a verified local/LAN admin MCP token or Inspector
// session to the primary enabled administrator account using an internal
// non-browser session row so all in-process Store and API guards work identically.
func (s *Store) EnsureSystemMCPSession(systemKey, slotLabel string) (User, string, MCPConnection, bool) {
	systemKey = strings.TrimSpace(systemKey)
	if systemKey == "" {
		return User{}, "", MCPConnection{}, false
	}
	internalLabel := "__system_mcp__"
	displayLabel := "system-mcp"
	if slotLabel == "debug-ui" {
		internalLabel = "__system_mcp_debug__"
		displayLabel = "debug-ui"
	}
	session := "mcp_sys:" + internalLabel + ":" + systemKey
	digest := sha256.Sum256([]byte(session))
	now := time.Now()
	nowUnix := now.Unix()

	var user User
	var expiresAt int64
	err := s.db.QueryRow(`SELECT u.id,u.username,u.role,u.enabled,u.created_at,ss.expires_at
		FROM mcp_connections mc JOIN sessions ss ON ss.id=mc.session_id JOIN users u ON u.id=ss.user_id
		WHERE ss.id=? AND mc.label=? AND u.enabled=1 AND u.role=?`,
		digest[:], internalLabel, RoleAdmin).
		Scan(&user.ID, &user.Username, &user.Role, &user.Enabled, &user.CreatedAt, &expiresAt)
	if err == nil && expiresAt > nowUnix+86400 {
		return user, session, MCPConnection{
			ID:        hex.EncodeToString(digest[:]),
			Label:     displayLabel,
			CanWrite:  true,
			ExpiresAt: expiresAt,
		}, true
	}

	tx, err := s.db.Begin()
	if err != nil {
		return User{}, "", MCPConnection{}, false
	}
	defer tx.Rollback()

	err = tx.QueryRow(`SELECT id,username,role,enabled,created_at FROM users
		WHERE role=? AND enabled=1 ORDER BY id LIMIT 1`, RoleAdmin).
		Scan(&user.ID, &user.Username, &user.Role, &user.Enabled, &user.CreatedAt)
	if err != nil {
		return User{}, "", MCPConnection{}, false
	}

	_, _ = tx.Exec(`DELETE FROM sessions WHERE id<>? AND id IN (
		SELECT session_id FROM mcp_connections WHERE label=?
	)`, digest[:], internalLabel)

	newExpires := now.Add(SessionLifetime).Unix()
	if _, err := tx.Exec(`INSERT INTO sessions(id,user_id,expires_at,created_at) VALUES(?,?,?,?)
		ON CONFLICT(id) DO UPDATE SET user_id=excluded.user_id, expires_at=excluded.expires_at`,
		digest[:], user.ID, newExpires, nowUnix); err != nil {
		return User{}, "", MCPConnection{}, false
	}
	if _, err := tx.Exec(`INSERT INTO mcp_connections(session_id,label,can_write) VALUES(?,?,1)
		ON CONFLICT(session_id) DO UPDATE SET label=excluded.label, can_write=1`,
		digest[:], internalLabel); err != nil {
		return User{}, "", MCPConnection{}, false
	}
	if err := tx.Commit(); err != nil {
		return User{}, "", MCPConnection{}, false
	}
	return user, session, MCPConnection{
		ID:        hex.EncodeToString(digest[:]),
		Label:     displayLabel,
		CanWrite:  true,
		CreatedAt: nowUnix,
		ExpiresAt: newExpires,
	}, true
}
