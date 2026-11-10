package server

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/lengsukq/lightisle/core/internal/smbmgmt"
)

func (a *API) smbStatus(w http.ResponseWriter, r *http.Request) {
	status, err := smbmgmt.Shared().Status(r.Context())
	if err != nil {
		writeSMBError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, status)
}

func (a *API) smbSetService(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	defer r.Body.Close()
	var req struct {
		Enabled *bool `json:"enabled"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil || req.Enabled == nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_smb_request"})
		return
	}
	status, err := smbmgmt.Shared().SetService(r.Context(), *req.Enabled)
	if err != nil {
		writeSMBError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, status)
}

func (a *API) smbAddShare(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	defer r.Body.Close()
	var req smbmgmt.AddRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_smb_request"})
		return
	}
	status, err := smbmgmt.Shared().AddShare(r.Context(), req)
	if err != nil {
		writeSMBError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, status)
}

func (a *API) smbUpdateShare(w http.ResponseWriter, r *http.Request) {
	recordName := r.PathValue("recordName")
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	defer r.Body.Close()
	var req smbmgmt.UpdateRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_smb_request"})
		return
	}
	status, err := smbmgmt.Shared().UpdateShare(r.Context(), recordName, req)
	if err != nil {
		writeSMBError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, status)
}

func (a *API) smbRemoveShare(w http.ResponseWriter, r *http.Request) {
	recordName := r.PathValue("recordName")
	status, err := smbmgmt.Shared().RemoveShare(r.Context(), recordName)
	if err != nil {
		writeSMBError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, status)
}

func writeSMBError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, smbmgmt.ErrInvalid):
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_smb_request"})
	case errors.Is(err, smbmgmt.ErrNotFound):
		jsonReply(w, http.StatusNotFound, map[string]string{"error": "smb_share_not_found"})
	case errors.Is(err, smbmgmt.ErrAlreadyExists):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "smb_share_already_exists"})
	case errors.Is(err, smbmgmt.ErrElevationRequired):
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "smb_elevation_required"})
	case errors.Is(err, smbmgmt.ErrProtectedPath):
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "smb_protected_path_rejected"})
	case errors.Is(err, smbmgmt.ErrPersonalGuest), errors.Is(err, smbmgmt.ErrLocalConfirmation):
		jsonReply(w, http.StatusForbidden, map[string]string{"error": err.Error()})
	case errors.Is(err, smbmgmt.ErrRootOffline):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "smb_root_offline"})
	default:
		jsonReply(w, http.StatusConflict, map[string]string{"error": "smb_operation_failed"})
	}
}
