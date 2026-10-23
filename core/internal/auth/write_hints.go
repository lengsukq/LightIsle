package auth

import "strings"

// WritablePaths returns display hints for one response using a single session
// and grant lookup. Hints are not authorization tokens: every mutation must
// still call CanAccess again, so a revoked grant takes effect immediately.
func (s *Store) WritablePaths(session string, paths []string) (map[string]bool, error) {
	if len(paths) > 256 {
		return nil, ErrInput
	}
	user, ok := s.Identity(session)
	if !ok {
		return nil, ErrForbidden
	}
	var grants []FileGrant
	if user.Role != RoleAdmin {
		var err error
		grants, err = s.grants(user.ID)
		if err != nil {
			return nil, err
		}
	}
	result := make(map[string]bool, len(paths))
	for _, name := range paths {
		result[name] = false
		if !validGrantPath(name) {
			continue
		}
		if user.Role == RoleAdmin {
			result[name] = true
			continue
		}
		for _, grant := range grants {
			if grant.CanWrite && (grant.Path == "." || name == grant.Path || strings.HasPrefix(name, grant.Path+"/")) {
				result[name] = true
				break
			}
		}
	}
	return result, nil
}
