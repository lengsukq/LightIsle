package server

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

// WebDAV credential self-service. Every account manages only its own
// credentials; the generated password is returned exactly once at creation.
func (a *API) davCredentials(w http.ResponseWriter, r *http.Request) {
	session := token(r)
	if r.Method == http.MethodPost {
		r.Body = http.MaxBytesReader(w, r.Body, 512)
		defer r.Body.Close()
		var request struct {
			Label string `json:"label"`
		}
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&request); err != nil {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_dav_request"})
			return
		}
		credential, password, err := a.auth.CreateDAVCredential(session, request.Label)
		switch {
		case err == nil:
			jsonReply(w, http.StatusOK, map[string]any{"credential": credential, "password": password})
		case errors.Is(err, auth.ErrDAVCredentialLimit):
			jsonReply(w, http.StatusConflict, map[string]string{"error": "dav_credential_limit_reached"})
		case errors.Is(err, auth.ErrForbidden):
			jsonReply(w, http.StatusForbidden, map[string]string{"error": "login_required"})
		default:
			jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "dav_credential_failed"})
		}
		return
	}
	credentials, err := a.auth.ListDAVCredentials(session)
	switch {
	case err == nil:
		jsonReply(w, http.StatusOK, map[string]any{"credentials": credentials})
	case errors.Is(err, auth.ErrForbidden):
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "login_required"})
	default:
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "dav_credential_failed"})
	}
}

func (a *API) davCredentialDelete(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_dav_request"})
		return
	}
	switch err := a.auth.RevokeDAVCredential(token(r), id); {
	case err == nil:
		jsonReply(w, http.StatusOK, map[string]any{"revoked": true})
	case errors.Is(err, auth.ErrNotFound):
		jsonReply(w, http.StatusNotFound, map[string]string{"error": "dav_credential_not_found"})
	case errors.Is(err, auth.ErrForbidden):
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "login_required"})
	default:
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "dav_credential_failed"})
	}
}
