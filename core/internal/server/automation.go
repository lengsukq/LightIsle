package server

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/automation"
	"github.com/lengsukq/lightisle/core/internal/notify"
)

// WithAutomation adds owner-session authorization to both global and root-scoped v2
// optional v2 root service surfaces without exposing script mutation APIs.
func WithAutomation(base http.Handler, store *auth.Store, manager *automation.Manager, hub *notify.Hub) http.Handler {
	if manager == nil {
		return base
	}
	a := &API{auth: store}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v2/automation/tasks", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		jsonReply(w, 200, map[string]any{"tasks": manager.List()})
	}))
	mux.HandleFunc("POST /api/v2/automation/refresh", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		if !automationMutation(w, r) {
			return
		}
		if err := manager.Reload(); err != nil {
			jsonReply(w, 500, map[string]string{"error": "automation_refresh_failed"})
			return
		}
		jsonReply(w, 200, map[string]any{"tasks": manager.List()})
	}))
	mux.HandleFunc("PUT /api/v2/automation/tasks/{id}", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		if !automationMutation(w, r) {
			return
		}
		var data struct {
			Enabled      bool                    `json:"enabled"`
			Schedule     automation.Schedule     `json:"schedule"`
			Notification automation.Notification `json:"notification"`
		}
		r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
		defer r.Body.Close()
		dec := json.NewDecoder(r.Body)
		dec.DisallowUnknownFields()
		if err := dec.Decode(&data); err != nil {
			jsonReply(w, 400, map[string]string{"error": "invalid_request"})
			return
		}
		if err := manager.Update(r.PathValue("id"), data.Enabled, data.Schedule, data.Notification); err != nil {
			automationFailure(w, err)
			return
		}
		jsonReply(w, 200, map[string]any{"tasks": manager.List()})
	}))
	mux.HandleFunc("DELETE /api/v2/automation/tasks/{id}", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		if !automationMutation(w, r) {
			return
		}
		if err := manager.Delete(r.PathValue("id")); err != nil {
			automationFailure(w, err)
			return
		}
		jsonReply(w, 200, map[string]bool{"deleted": true})
	}))
	mux.HandleFunc("GET /api/v2/automation/tasks/{id}/runs", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		runs, err := manager.History(r.PathValue("id"))
		if err != nil {
			automationFailure(w, err)
			return
		}
		jsonReply(w, 200, map[string]any{"runs": runs})
	}))
	mux.HandleFunc("GET /api/v2/automation/channels", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		jsonReply(w, 200, map[string]any{"channels": hub.ConfiguredChannels()})
	}))
	mux.Handle("/", base)
	return securityHeaders(mux)
}
func automationMutation(w http.ResponseWriter, r *http.Request) bool {
	// A cross-site form must not be able to schedule arbitrary code execution.
	if r.Header.Get("X-LightIsle-Request") != "1" {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "request_header_required"})
		return false
	}
	return true
}
func automationFailure(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, automation.ErrInvalid):
		jsonReply(w, 400, map[string]string{"error": "automation_invalid_task"})
	case errors.Is(err, automation.ErrNotFound):
		jsonReply(w, 404, map[string]string{"error": "automation_task_not_found"})
	case errors.Is(err, automation.ErrBusy):
		jsonReply(w, 409, map[string]string{"error": "automation_task_running"})
	default:
		jsonReply(w, 500, map[string]string{"error": "automation_operation_failed"})
	}
}
