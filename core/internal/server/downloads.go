package server

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/lengsukq/lightisle/core/internal/downloads"
)

// The download center degrades honestly: with aria2 missing (or the manager
// not wired in single-binary tests) every endpoint reports the stable
// download_unavailable reason instead of pretending tasks exist.

func (a *API) downloadStatus(w http.ResponseWriter, r *http.Request) {
	if a.downloads == nil {
		jsonReply(w, http.StatusOK, map[string]any{"available": false, "reason": "aria2_not_installed"})
		return
	}
	available, reason := a.downloads.Available()
	payload := map[string]any{"available": available}
	if version := a.downloads.Version(); version != "" {
		payload["version"] = version
	}
	if !available && reason != "" {
		payload["reason"] = reason
	}
	jsonReply(w, http.StatusOK, payload)
}

func (a *API) downloadsUnavailable(w http.ResponseWriter) bool {
	if a.downloads == nil {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "download_unavailable"})
		return true
	}
	if available, _ := a.downloads.Available(); !available {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "download_unavailable"})
		return true
	}
	return false
}

func (a *API) downloadList(w http.ResponseWriter, r *http.Request) {
	if a.downloadsUnavailable(w) {
		return
	}
	user, ok := a.auth.Identity(token(r))
	if !ok {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	tasks, err := a.downloads.List(user.ID)
	if err != nil {
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "download_list_failed"})
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"tasks": tasks})
}

func (a *API) downloadCreate(w http.ResponseWriter, r *http.Request) {
	if a.downloadsUnavailable(w) {
		return
	}
	user, ok := a.auth.Identity(token(r))
	if !ok {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	defer r.Body.Close()
	var request struct {
		URL         string `json:"url"`
		Destination string `json:"destination"`
		MaxBytes    int64  `json:"maxBytes"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "download_invalid_request"})
		return
	}
	// Only members with a write grant on the destination may create tasks;
	// the same grant is re-checked when a finished download is published.
	if !a.allowFile(w, r, request.Destination, true) {
		return
	}
	task, err := a.downloads.Create(user.ID, request.URL, request.Destination, request.MaxBytes)
	switch {
	case err == nil:
		jsonReply(w, http.StatusAccepted, map[string]any{"task": task})
	case errors.Is(err, downloads.ErrInput):
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "download_invalid_request"})
	case errors.Is(err, downloads.ErrBusy):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "download_limit_reached"})
	default:
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "download_unavailable"})
	}
}

func (a *API) downloadAction(w http.ResponseWriter, r *http.Request) {
	if a.downloadsUnavailable(w) {
		return
	}
	user, ok := a.auth.Identity(token(r))
	if !ok {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 512)
	defer r.Body.Close()
	var request struct {
		Action string `json:"action"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "download_invalid_request"})
		return
	}
	task, err := a.downloads.Action(user.ID, r.PathValue("id"), request.Action)
	if err != nil {
		downloadError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"task": task})
}

func (a *API) downloadDelete(w http.ResponseWriter, r *http.Request) {
	if a.downloadsUnavailable(w) {
		return
	}
	user, ok := a.auth.Identity(token(r))
	if !ok {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	if err := a.downloads.Delete(user.ID, r.PathValue("id")); err != nil {
		downloadError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"deleted": true})
}

func downloadError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, downloads.ErrNotFound):
		jsonReply(w, http.StatusNotFound, map[string]string{"error": "download_not_found"})
	case errors.Is(err, downloads.ErrInput):
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "download_invalid_request"})
	default:
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "download_action_failed"})
	}
}
