package server

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/lengsukq/lightisle/core/internal/diskhealth"
	"github.com/lengsukq/lightisle/core/internal/diskmgmt"
)

// The native Mac and Web admin front ends use the exact same diskmgmt
// validation and action implementation; there is no writable disk API for
// unprivileged members or unauthenticated callers.
func (a *API) diskList(w http.ResponseWriter, r *http.Request) {
	disks, err := diskmgmt.Shared().List(r.Context())
	if err != nil {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "drive_discovery_unavailable"})
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"disks": disks})
}

// diskSmart serves the best-effort SMART health report for one drive. The
// diskhealth package degrades to a machine reason code when smartctl is
// unavailable; it never fabricates a healthy answer.
func (a *API) diskSmart(w http.ResponseWriter, r *http.Request) {
	report, err := diskhealth.Shared().Report(r.Context(), r.PathValue("id"))
	if err != nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_drive_request"})
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"report": report})
}

func (a *API) diskAction(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	defer r.Body.Close()
	var req diskmgmt.Request
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_drive_request"})
		return
	}
	disks, err := diskmgmt.Shared().Do(r.Context(), req)
	switch {
	case err == nil:
		jsonReply(w, http.StatusOK, map[string]any{"disks": disks})
	case errors.Is(err, diskmgmt.ErrInvalid):
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_drive_request"})
	case errors.Is(err, diskmgmt.ErrChanged):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "drive_identity_changed_refresh_required"})
	case errors.Is(err, diskmgmt.ErrProtected):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "drive_in_use_or_protected"})
	case errors.Is(err, diskmgmt.ErrBusy):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "drive_operation_busy"})
	case errors.Is(err, diskmgmt.ErrUnsupported):
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "drive_operation_not_supported"})
	default:
		jsonReply(w, http.StatusConflict, map[string]string{"error": "diskutil_operation_failed"})
	}
}
