package server

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/downloads"
)

// Network transfers require aria2 for generic/magnet downloads, while yt-dlp,
// webarchive, the journal, cancellation and local publication recovery remain
// usable independently.

type downloadStatusResponse struct {
	downloads.Status
	NetworkAllowed bool `json:"networkAllowed"`
}

func (a *API) downloadStatus(w http.ResponseWriter, r *http.Request) {
	user, ok := a.auth.Identity(token(r))
	if !ok {
		writeAPIErrorCode(w, http.StatusUnauthorized, "authentication_required")
		return
	}
	networkAllowed := user.Role == auth.RoleAdmin
	if a.downloads == nil {
		jsonReply(w, http.StatusOK, downloadStatusResponse{
			Status: downloads.Status{
				Available:           false,
				Reason:              "aria2_not_installed",
				Aria2Available:      false,
				Aria2Reason:         "aria2_not_installed",
				YtDlpAvailable:      false,
				YtDlpReason:         "ytdlp_not_installed",
				WebArchiveAvailable: false,
			},
			NetworkAllowed: networkAllowed,
		})
		return
	}
	jsonReply(w, http.StatusOK, downloadStatusResponse{
		Status:         a.downloads.Status(),
		NetworkAllowed: networkAllowed,
	})
}

func (a *API) downloadsUnavailable(w http.ResponseWriter) bool {
	if a.downloads == nil {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "download_unavailable")
		return true
	}
	if available, _ := a.downloads.Available(); !available {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "download_unavailable")
		return true
	}
	return false
}

func (a *API) downloadList(w http.ResponseWriter, r *http.Request) {
	if a.downloads == nil {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "download_unavailable")
		return
	}
	user, ok := a.auth.Identity(token(r))
	if !ok {
		writeAPIErrorCode(w, http.StatusUnauthorized, "authentication_required")
		return
	}
	tasks, err := a.downloads.List(user.ID)
	if err != nil {
		writeAPIErrorCode(w, http.StatusInternalServerError, "download_list_failed")
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"tasks": tasks})
}

func (a *API) downloadCreate(w http.ResponseWriter, r *http.Request) {
	if a.downloads == nil {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "download_unavailable")
		return
	}
	user, ok := a.auth.Identity(token(r))
	if !ok {
		writeAPIErrorCode(w, http.StatusUnauthorized, "authentication_required")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
	defer r.Body.Close()
	var request struct {
		URL         string                   `json:"url"`
		Destination string                   `json:"destination"`
		MaxBytes    int64                    `json:"maxBytes"`
		Engine      string                   `json:"engine"`
		Options     *downloads.EngineOptions `json:"options"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || downloads.ValidateDestination(request.Destination) != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "download_invalid_request")
		return
	}
	engine, err := downloads.NormalizeEngine(request.Engine)
	if err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "download_invalid_request")
		return
	}
	if engine == downloads.EngineAria2 && a.downloadsUnavailable(w) {
		return
	}
	// Only members with a write grant on the destination may create tasks;
	// the same grant is re-checked when a finished download is published.
	if a.rootServer != nil && a.rootServer.registry != nil {
		root, ok := a.rootServer.registry.Default()
		if !ok {
			writeAPIErrorCode(w, http.StatusServiceUnavailable, "default_root_not_configured")
			return
		}
		if !a.auth.CanAccessRoot(token(r), root.ID, request.Destination, true, false) {
			writeAPIErrorCode(w, http.StatusForbidden, "file_permission_denied")
			return
		}
	} else if !a.allowFile(w, r, request.Destination, true) {
		return
	}
	var engineOpts downloads.EngineOptions
	if request.Options != nil {
		engineOpts = *request.Options
	}
	task, err := a.downloads.CreateWithEngine(user.ID, engine, request.URL, request.Destination, request.MaxBytes, engineOpts)
	switch {
	case err == nil:
		jsonReply(w, http.StatusAccepted, map[string]any{"task": task})
	case errors.Is(err, downloads.ErrFetchForbidden):
		downloadError(w, err)
	case errors.Is(err, downloads.ErrInput):
		writeAPIErrorCode(w, http.StatusBadRequest, "download_invalid_request")
	case errors.Is(err, downloads.ErrBusy):
		writeAPIErrorCode(w, http.StatusConflict, "download_limit_reached")
	case errors.Is(err, downloads.ErrPermission):
		writeAPIErrorCode(w, http.StatusForbidden, "download_permission_revoked")
	case errors.Is(err, downloads.ErrAccountingPending):
		writeAPIErrorCode(w, http.StatusConflict, "download_storage_accounting_pending")
	case errors.Is(err, downloads.ErrYtDlpNotAvailable):
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "ytdlp_not_installed")
	case errors.Is(err, downloads.ErrRootChanged), errors.Is(err, downloads.ErrRootUnbound), errors.Is(err, downloads.ErrRootUnavailable):
		downloadError(w, err)
	default:
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "download_unavailable")
	}
}

func (a *API) downloadAction(w http.ResponseWriter, r *http.Request) {
	if a.downloads == nil {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "download_unavailable")
		return
	}
	user, ok := a.auth.Identity(token(r))
	if !ok {
		writeAPIErrorCode(w, http.StatusUnauthorized, "authentication_required")
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
		writeAPIErrorCode(w, http.StatusBadRequest, "download_invalid_request")
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
	if a.downloads == nil {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "download_unavailable")
		return
	}
	user, ok := a.auth.Identity(token(r))
	if !ok {
		writeAPIErrorCode(w, http.StatusUnauthorized, "authentication_required")
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
		writeAPIErrorCode(w, http.StatusNotFound, "download_not_found")
	case errors.Is(err, downloads.ErrInput):
		writeAPIErrorCode(w, http.StatusBadRequest, "download_invalid_request")
	case errors.Is(err, downloads.ErrYtDlpNotAvailable):
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "ytdlp_not_installed")
	case errors.Is(err, downloads.ErrNotAvailable):
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "download_unavailable")
	case errors.Is(err, downloads.ErrFetchForbidden):
		writeAPIErrorCode(w, http.StatusForbidden, "download_network_admin_only")
	case errors.Is(err, downloads.ErrPermission):
		writeAPIErrorCode(w, http.StatusForbidden, "download_permission_revoked")
	case errors.Is(err, downloads.ErrRootChanged):
		writeAPIErrorCode(w, http.StatusConflict, "download_root_changed")
	case errors.Is(err, downloads.ErrRootUnbound):
		writeAPIErrorCode(w, http.StatusConflict, "download_root_unbound")
	case errors.Is(err, downloads.ErrRootUnavailable):
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "download_root_unavailable")
	default:
		writeAPIErrorCode(w, http.StatusInternalServerError, "download_action_failed")
	}
}
