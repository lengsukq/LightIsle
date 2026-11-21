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
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "drive_discovery_unavailable")
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"disks": disks})
}

// diskSmart serves the best-effort SMART health report for one drive. The
// diskhealth package degrades to a machine reason code when smartctl is
// unavailable; it never fabricates a healthy answer.
func (a *API) diskSmart(w http.ResponseWriter, r *http.Request) {
	d, code := discoveredDrive(r)
	if code != http.StatusOK {
		writeAPIErrorCode(w, code, "disk_not_available_or_identity_unknown")
		return
	}
	report, err := diskhealth.Shared().Report(r.Context(), d.ID)
	if err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_drive_request")
		return
	}
	risk := "unknown"
	recorded := false
	if a.journal != nil && d.Identity != "" {
		if sample, e := a.journal.RecordDiskHealth(d.Identity, report); e == nil {
			risk = sample.Risk
			recorded = true
		}
	}
	jsonReply(w, http.StatusOK, map[string]any{"report": report, "risk": risk, "historyRecorded": recorded})
}

// Re-resolve every request against the currently enumerated external volume.
// A reused BSD disk number may not observe a previous volume's private history.
func discoveredDrive(r *http.Request) (diskmgmt.Disk, int) {
	id := r.PathValue("id")
	if _, ok := diskhealth.NormalizeDevice(id); !ok {
		return diskmgmt.Disk{}, http.StatusBadRequest
	}
	disks, err := diskmgmt.Shared().List(r.Context())
	if err != nil {
		return diskmgmt.Disk{}, http.StatusServiceUnavailable
	}
	for _, d := range disks {
		if d.ID == id && d.External {
			return d, http.StatusOK
		}
	}
	return diskmgmt.Disk{}, http.StatusNotFound
}

func (a *API) diskSmartHistory(w http.ResponseWriter, r *http.Request) {
	d, code := discoveredDrive(r)
	if code != http.StatusOK {
		writeAPIErrorCode(w, code, "disk_not_available_or_identity_unknown")
		return
	}
	if a.journal == nil || d.Identity == "" {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "disk_health_history_unavailable")
		return
	}
	samples, err := a.journal.DiskHealthHistory(d.Identity, 120)
	if err != nil {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "disk_health_history_unavailable")
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"samples": samples, "retentionDays": 30, "maxSamplesPerDisk": 360,
		"sampling": "on_demand",
	})
}

func (a *API) diskAction(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	defer r.Body.Close()
	var req diskmgmt.Request
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_drive_request")
		return
	}
	disks, err := diskmgmt.Shared().Do(r.Context(), req)
	switch {
	case err == nil:
		jsonReply(w, http.StatusOK, map[string]any{"disks": disks})
	case errors.Is(err, diskmgmt.ErrInvalid):
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_drive_request")
	case errors.Is(err, diskmgmt.ErrChanged):
		writeAPIErrorCode(w, http.StatusConflict, "drive_identity_changed_refresh_required")
	case errors.Is(err, diskmgmt.ErrProtected):
		writeAPIErrorCode(w, http.StatusConflict, "drive_in_use_or_protected")
	case errors.Is(err, diskmgmt.ErrBusy):
		writeAPIErrorCode(w, http.StatusConflict, "drive_operation_busy")
	case errors.Is(err, diskmgmt.ErrUnsupported):
		writeAPIErrorCode(w, http.StatusForbidden, "drive_operation_not_supported")
	default:
		writeAPIErrorCode(w, http.StatusConflict, "diskutil_operation_failed")
	}
}
