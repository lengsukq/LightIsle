package server

import (
	"net/http"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func (a *API) allowFile(w http.ResponseWriter, r *http.Request, p string, write bool) bool {
	if a.auth != nil && a.canAccess(token(r), p, write, false) {
		return true
	}
	writeAPIErrorCode(w, http.StatusForbidden, "file_permission_denied")
	return false
}

// allowMediaAsset hides whether a guessed media ID exists outside the
// caller's readable subtree. The root-scoped index is shared by users, so an
// ID lookup must not turn into an existence oracle before its path is checked.
// A readable asset that the caller cannot modify still returns 403 for a
// write operation, matching ordinary file mutation behavior.
func (a *API) allowMediaAsset(w http.ResponseWriter, r *http.Request, p string, write bool, notFoundCode ...string) bool {
	if a.rootID != "" && (a.auth == nil || !a.canAccess(token(r), p, false, false)) {
		code := "not_found"
		if len(notFoundCode) > 0 && notFoundCode[0] != "" {
			code = notFoundCode[0]
		}
		writeAPIErrorCode(w, http.StatusNotFound, code)
		return false
	}
	return a.allowFile(w, r, p, write)
}
func (a *API) canAccess(session, p string, write, traverse bool) bool {
	if a.rootID != "" {
		return a.auth != nil && a.auth.CanAccessRoot(session, a.rootID, p, write, traverse)
	}
	// Global/shared v2 requests are not generation-bound and do not participate
	// in the personal-home ledger. Never let a shared-directory grant
	// (including admin's '.') reach a private physical-root subtree.
	if managedStorageName(p) {
		return false
	}
	return a.auth != nil && a.auth.CanAccess(session, p, write, traverse)
}
func (a *API) canSee(session, p string) bool {
	if a.rootID != "" {
		return a.auth != nil && a.auth.CanSeeRoot(session, a.rootID, p)
	}
	if managedStorageName(p) {
		return false
	}
	return a.auth != nil && a.auth.CanSee(session, p)
}
func (a *API) searchRoots(session, base string) ([]string, error) {
	if a.rootID != "" {
		return a.auth.SearchRootsRoot(session, a.rootID, base)
	}
	if managedStorageName(base) {
		return nil, auth.ErrForbidden
	}
	return a.auth.SearchRoots(session, base)
}
func (a *API) allowMedia(w http.ResponseWriter, r *http.Request) bool {
	_, ok := a.mediaRoots(w, r)
	return ok
}
func (a *API) mediaRoots(w http.ResponseWriter, r *http.Request) ([]string, bool) {
	if a.auth == nil {
		writeAPIErrorCode(w, http.StatusForbidden, "file_permission_denied")
		return nil, false
	}
	roots, err := a.searchRoots(token(r), ".")
	if err != nil || len(roots) == 0 {
		writeAPIErrorCode(w, http.StatusForbidden, "file_permission_denied")
		return nil, false
	}
	return roots, true
}
func (a *API) requireMedia(next http.HandlerFunc) http.HandlerFunc {
	return a.requireLogin(func(w http.ResponseWriter, r *http.Request) {
		if a.allowMedia(w, r) {
			next(w, r)
		}
	})
}
