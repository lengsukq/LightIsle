package server

import (
	"errors"
	"net/http"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func (a *API) listOwnSessions(w http.ResponseWriter, r *http.Request) {
	sessions, truncated, err := a.auth.ListSessions(token(r))
	if err != nil {
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "sessions_unavailable"})
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"sessions": sessions, "truncated": truncated})
}

func (a *API) revokeOwnSession(w http.ResponseWriter, r *http.Request) {
	isCurrent, err := a.auth.RevokeSession(token(r), r.PathValue("id"))
	if err != nil {
		status, code := http.StatusInternalServerError, "session_revoke_failed"
		if errors.Is(err, auth.ErrInput) {
			status, code = http.StatusBadRequest, "invalid_session_id"
		}
		if errors.Is(err, auth.ErrForbidden) {
			status, code = http.StatusUnauthorized, "authentication_required"
		}
		jsonReply(w, status, map[string]string{"error": code})
		return
	}
	if isCurrent {
		expireLoginCookie(w, r)
	}
	jsonReply(w, http.StatusOK, map[string]bool{"revoked": true, "current": isCurrent})
}

func (a *API) revokeOtherSessions(w http.ResponseWriter, r *http.Request) {
	count, err := a.auth.RevokeOtherSessions(token(r))
	if err != nil {
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "session_revoke_failed"})
		return
	}
	jsonReply(w, http.StatusOK, map[string]int64{"revoked": count})
}

func expireLoginCookie(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{
		Name: sessionCookie, Value: "", Path: "/", HttpOnly: true,
		Secure: r.TLS != nil, SameSite: http.SameSiteStrictMode, MaxAge: -1,
	})
}
