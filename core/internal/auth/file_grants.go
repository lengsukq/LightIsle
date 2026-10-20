package auth

import (
	"path"
	"sort"
	"strings"
)

// FileGrant applies to an entire relative directory subtree. Member accounts
// have no access until an administrator explicitly grants a directory.
type FileGrant struct {
	UserID   int64  `json:"userId"`
	Path     string `json:"path"`
	CanWrite bool   `json:"canWrite"`
}

func validGrantPath(name string) bool {
	if name == "." {
		return true
	}
	if name == "" || strings.HasPrefix(name, "/") || strings.ContainsAny(name, "\\\x00") || path.Clean(name) != name {
		return false
	}
	for _, p := range strings.Split(name, "/") {
		if p == "" || p == "." || p == ".." || strings.HasPrefix(p, ".lightisle-") {
			return false
		}
	}
	return true
}

func (s *Store) SetFileGrant(actorToken string, userID int64, name string, write bool) error {
	actor, ok := s.Identity(actorToken)
	if !ok || actor.Role != RoleAdmin {
		return ErrForbidden
	}
	if !validGrantPath(name) {
		return ErrInput
	}
	user, err := s.GetUser(userID)
	if err != nil {
		return err
	}
	if user.Role != RoleMember {
		return ErrForbidden
	}
	w := 0
	if write {
		w = 1
	}
	_, err = s.db.Exec(`INSERT INTO file_grants(user_id,path,can_write) VALUES(?,?,?)
	ON CONFLICT(user_id,path) DO UPDATE SET can_write=excluded.can_write`, userID, name, w)
	return err
}

func (s *Store) RemoveFileGrant(actorToken string, userID int64, name string) error {
	actor, ok := s.Identity(actorToken)
	if !ok || actor.Role != RoleAdmin {
		return ErrForbidden
	}
	if !validGrantPath(name) {
		return ErrInput
	}
	_, err := s.db.Exec("DELETE FROM file_grants WHERE user_id=? AND path=?", userID, name)
	return err
}

func (s *Store) FileGrants(actorToken string, userID int64) ([]FileGrant, error) {
	actor, ok := s.Identity(actorToken)
	if !ok || actor.Role != RoleAdmin {
		return nil, ErrForbidden
	}
	return s.grants(userID)
}

func (s *Store) grants(userID int64) ([]FileGrant, error) {
	rows, err := s.db.Query("SELECT path,can_write FROM file_grants WHERE user_id=? ORDER BY path", userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []FileGrant{}
	for rows.Next() {
		var g FileGrant
		var write int
		g.UserID = userID
		if err := rows.Scan(&g.Path, &write); err != nil {
			return nil, err
		}
		g.CanWrite = write == 1
		result = append(result, g)
	}
	return result, rows.Err()
}

// CanAccess returns true for granted subtree access. For listing only,
// an ancestor of a granted directory is traversable, but never writable.
func (s *Store) CanAccess(session, name string, write, traverse bool) bool {
	if !validGrantPath(name) {
		return false
	}
	user, ok := s.Identity(session)
	if !ok {
		return false
	}
	if user.Role == RoleAdmin {
		return true
	}
	gs, err := s.grants(user.ID)
	if err != nil {
		return false
	}
	for _, g := range gs {
		if (g.Path == "." || name == g.Path || strings.HasPrefix(name, g.Path+"/")) && (!write || g.CanWrite) {
			return true
		}
		if traverse && !write && (name == "." || strings.HasPrefix(g.Path, name+"/")) {
			return true
		}
	}
	return false
}

func (s *Store) CanSee(session, name string) bool { return s.CanAccess(session, name, false, true) }

// SearchRoots enumerates the *authorized* subtrees under a requested base.
// Scanning an arbitrary ancestor and filtering matches afterwards leaks file
// activity, permits expensive private-directory scans and is not acceptable.
func (s *Store) SearchRoots(session, base string) ([]string, error) {
	if !validGrantPath(base) {
		return nil, ErrInput
	}
	u, ok := s.Identity(session)
	if !ok {
		return nil, ErrForbidden
	}
	if u.Role == RoleAdmin {
		return []string{base}, nil
	}
	grants, err := s.grants(u.ID)
	if err != nil {
		return nil, err
	}
	roots := make([]string, 0, len(grants))
	for _, grant := range grants {
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
