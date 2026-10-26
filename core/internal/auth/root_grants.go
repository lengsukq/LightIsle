package auth

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// RootGrant belongs to exactly one registered physical root. Legacy grants
// never carry over to a new root, even for an identical relative path.
type RootGrant struct {
	UserID   int64  `json:"userId"`
	RootID   string `json:"rootId"`
	Path     string `json:"path"`
	CanWrite bool   `json:"canWrite"`
}

// Personal homes are reserved regardless of case: most macOS APFS volumes
// resolve 'users/' and 'Users/' to the same directory inode.
func isPersonalHomePath(name string) bool {
	return strings.EqualFold(name, "Users") ||
		(len(name) > 6 && name[5] == '/' && strings.EqualFold(name[:5], "Users"))
}

// A broad historical root grant must not permit member writes into the
// namespace container or access to any sibling user's private directories.
func denyPersonalHomeForMember(name string, userID int64, write bool) bool {
	if !isPersonalHomePath(name) {
		return false
	}
	parts := strings.Split(name, "/")
	if len(parts) == 1 {
		return write
	}
	return !strings.EqualFold(parts[1], fmt.Sprintf("u%d", userID))
}

func validRootID(id string) bool {
	if len(id) != 32 {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}
func (s *Store) SetRootGrant(session string, userID int64, rootID, relative string, write bool) error {
	actor, ok := s.Identity(session)
	if !ok || actor.Role != RoleAdmin {
		return ErrForbidden
	}
	if !validRootID(rootID) || !validGrantPath(relative) {
		return ErrInput
	}
	v := 0
	if write {
		v = 1
	}
	if s.afterRootGrantAuthorization != nil {
		s.afterRootGrantAuthorization()
	}
	// A configured root must be checked by the caller against RootRegistry;
	// this transaction stores a grant only while both the admin session and
	// target member remain authorized.
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	valid, err := rootAdminSessionValid(tx, session, actor.ID)
	if err != nil {
		return err
	}
	if !valid {
		return ErrForbidden
	}
	var role string
	var enabled int
	if err := tx.QueryRow("SELECT role,enabled FROM users WHERE id=?", userID).Scan(&role, &enabled); errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	} else if err != nil {
		return err
	}
	if role != RoleMember || enabled != 1 {
		return ErrForbidden
	}
	sessionDigest := sha256.Sum256([]byte(session))
	result, err := tx.Exec(`INSERT INTO root_file_grants(user_id,root_id,path,can_write)
		SELECT ?,?,?,? WHERE EXISTS(SELECT 1 FROM sessions ss JOIN users actor ON actor.id=ss.user_id
			WHERE ss.id=? AND ss.user_id=? AND ss.expires_at>? AND actor.enabled=1 AND actor.role=?)
		AND EXISTS(SELECT 1 FROM users target WHERE target.id=? AND target.role=? AND target.enabled=1)
		ON CONFLICT(user_id,root_id,path) DO UPDATE SET can_write=excluded.can_write`,
		userID, rootID, relative, v, sessionDigest[:], actor.ID, time.Now().Unix(), RoleAdmin, userID, RoleMember)
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected != 1 {
		return ErrForbidden
	}
	return tx.Commit()
}
func (s *Store) RemoveRootGrant(session string, userID int64, rootID, relative string) error {
	actor, ok := s.Identity(session)
	if !ok || actor.Role != RoleAdmin {
		return ErrForbidden
	}
	if !validRootID(rootID) || !validGrantPath(relative) {
		return ErrInput
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	valid, err := rootAdminSessionValid(tx, session, actor.ID)
	if err != nil {
		return err
	}
	if !valid {
		return ErrForbidden
	}
	if _, err := tx.Exec(`DELETE FROM root_file_grants WHERE user_id=? AND root_id=? AND path=?`, userID, rootID, relative); err != nil {
		return err
	}
	// Remove links that lost their last covering grant in the same commit.
	// A later grant cannot revive a bearer token that was once revoked.
	if _, err := tx.Exec(`DELETE FROM root_file_shares
		WHERE user_id=? AND root_id=?
		AND EXISTS(SELECT 1 FROM users u WHERE u.id=root_file_shares.user_id AND u.role=?)
		AND NOT EXISTS(SELECT 1 FROM root_file_grants g
			WHERE g.user_id=root_file_shares.user_id AND g.root_id=root_file_shares.root_id
			AND (g.path='.' OR root_file_shares.file_path=g.path
				OR substr(root_file_shares.file_path,1,length(g.path)+1)=g.path||'/'))`,
		userID, rootID, RoleMember); err != nil {
		return err
	}
	return tx.Commit()
}

func rootAdminSessionValid(tx *sql.Tx, session string, userID int64) (bool, error) {
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
func (s *Store) RootGrants(session string, userID int64, rootID string) ([]RootGrant, error) {
	actor, ok := s.Identity(session)
	if !ok || actor.Role != RoleAdmin {
		return nil, ErrForbidden
	}
	if !validRootID(rootID) {
		return nil, ErrInput
	}
	return s.rootGrants(userID, rootID)
}
func (s *Store) rootGrants(userID int64, rootID string) ([]RootGrant, error) {
	rows, err := s.db.Query(`SELECT path,can_write FROM root_file_grants
 WHERE user_id=? AND root_id=? ORDER BY path`, userID, rootID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	grants := []RootGrant{}
	for rows.Next() {
		var g RootGrant
		var v int
		g.UserID = userID
		g.RootID = rootID
		if err = rows.Scan(&g.Path, &v); err != nil {
			return nil, err
		}
		g.CanWrite = v == 1
		grants = append(grants, g)
	}
	return grants, rows.Err()
}
func (s *Store) CanAccessRoot(session, rootID, relative string, write, traverse bool) bool {
	if !validRootID(rootID) || !validGrantPath(relative) {
		return false
	}
	u, ok := s.Identity(session)
	if !ok {
		return false
	}
	if u.Role == RoleAdmin {
		return true
	}
	if denyPersonalHomeForMember(relative, u.ID, write) {
		return false
	}
	// The top-level Users namespace is private even when an older broad
	// grant (such as '.') exists on this physical root. A member may traverse
	// Users to reach their own user-ID directory, never a sibling account.
	grants, err := s.rootGrants(u.ID, rootID)
	if err != nil {
		return false
	}
	for _, g := range grants {
		if (g.Path == "." || relative == g.Path || strings.HasPrefix(relative, g.Path+"/")) && (!write || g.CanWrite) {
			return true
		}
		if traverse && !write && (relative == "." || strings.HasPrefix(g.Path, relative+"/")) {
			return true
		}
	}
	return false
}

func (s *Store) CanSeeRoot(session, rootID, relative string) bool {
	return s.CanAccessRoot(session, rootID, relative, false, true)
}

// SearchRootsRoot returns only subtrees that a session may traverse beneath a
// specific registered root. The caller must search each returned relative
// path using that root's Store; paths and grants from another root never enter
// this result.
func (s *Store) SearchRootsRoot(session, rootID, base string) ([]string, error) {
	if !validRootID(rootID) || !validGrantPath(base) {
		return nil, ErrInput
	}
	user, ok := s.Identity(session)
	if !ok {
		return nil, ErrForbidden
	}
	if user.Role == RoleAdmin {
		return []string{base}, nil
	}
	if denyPersonalHomeForMember(base, user.ID, false) {
		return nil, ErrForbidden
	}
	grants, err := s.rootGrants(user.ID, rootID)
	if err != nil {
		return nil, err
	}
	// A physical root containing personal homes must never expose its whole
	// media index through a historical '.' (or 'Users') grant. Scoped media
	// readers use this list directly for timelines/counts and cannot subtract
	// individual private files after aggregation.
	var hasPersonalHomes bool
	if err := s.db.QueryRow("SELECT EXISTS(SELECT 1 FROM user_storage_locations WHERE root_id=?)", rootID).
		Scan(&hasPersonalHomes); err != nil {
		return nil, err
	}
	roots := make([]string, 0, len(grants))
	for _, grant := range grants {
		if hasPersonalHomes {
			if grant.Path == "." || strings.EqualFold(grant.Path, "Users") {
				continue
			}
			p := strings.Split(grant.Path, "/")
			if len(p) > 1 && strings.EqualFold(p[0], "Users") && !strings.EqualFold(p[1], fmt.Sprintf("u%d", user.ID)) {
				continue
			}
		}
		if grant.Path == "." || grant.Path == base || strings.HasPrefix(base, grant.Path+"/") {
			roots = append(roots, base)
			continue
		}
		if base == "." || strings.HasPrefix(grant.Path, base+"/") {
			roots = append(roots, grant.Path)
		}
	}
	sort.Strings(roots)
	filtered := roots[:0]
	for _, p := range roots {
		if len(filtered) > 0 && (filtered[len(filtered)-1] == p || filtered[len(filtered)-1] == "." ||
			strings.HasPrefix(p, filtered[len(filtered)-1]+"/")) {
			continue
		}
		filtered = append(filtered, p)
	}
	return filtered, nil
}
func (s *Store) UserCanWriteRoot(userID int64, rootID, relative string) (bool, error) {
	if !validRootID(rootID) || !validGrantPath(relative) || userID <= 0 {
		return false, nil
	}
	user, err := s.GetUser(userID)
	if err == ErrNotFound {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !user.Enabled {
		return false, nil
	}
	if user.Role == RoleAdmin {
		return true, nil
	}
	// Match CanAccessRoot's private-user boundary even for background workers
	// and admin status hints that operate on a user ID rather than a session.
	if denyPersonalHomeForMember(relative, userID, true) {
		return false, nil
	}
	grants, err := s.rootGrants(userID, rootID)
	if err != nil {
		return false, err
	}
	for _, g := range grants {
		if g.CanWrite && (g.Path == "." || relative == g.Path || strings.HasPrefix(relative, g.Path+"/")) {
			return true, nil
		}
	}
	return false, nil
}

// WritableRootPaths returns UI capability hints scoped to one logical root.
// These values are descriptive only; every mutation must still use
// CanAccessRoot at the point of the operation.
func (s *Store) WritableRootPaths(session, rootID string, paths []string) (map[string]bool, error) {
	if !validRootID(rootID) || len(paths) > 256 {
		return nil, ErrInput
	}
	user, ok := s.Identity(session)
	if !ok {
		return nil, ErrForbidden
	}
	var grants []RootGrant
	if user.Role != RoleAdmin {
		var err error
		grants, err = s.rootGrants(user.ID, rootID)
		if err != nil {
			return nil, err
		}
	}
	result := make(map[string]bool, len(paths))
	for _, name := range paths {
		if user.Role != RoleAdmin && denyPersonalHomeForMember(name, user.ID, true) {
			result[name] = false
			continue
		}
		if user.Role == RoleAdmin && validGrantPath(name) {
			result[name] = true
			continue
		}
		for _, grant := range grants {
			if validGrantPath(name) && grant.CanWrite &&
				(grant.Path == "." || name == grant.Path || strings.HasPrefix(name, grant.Path+"/")) {
				result[name] = true
				break
			}
		}
		if _, exists := result[name]; !exists {
			result[name] = false
		}
	}
	return result, nil
}

func (s *Store) UserCanReadRoot(userID int64, rootID, relative string) bool {
	if !validRootID(rootID) || !validGrantPath(relative) || userID <= 0 {
		return false
	}
	user, err := s.GetUser(userID)
	if err != nil || !user.Enabled {
		return false
	}
	if user.Role == RoleAdmin {
		return true
	}
	if denyPersonalHomeForMember(relative, userID, false) {
		return false
	}
	grants, err := s.rootGrants(userID, rootID)
	if err != nil {
		return false
	}
	for _, grant := range grants {
		if grant.Path == "." || relative == grant.Path || strings.HasPrefix(relative, grant.Path+"/") {
			return true
		}
	}
	return false
}
