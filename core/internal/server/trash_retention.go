package server

import (
	"net/http"

	"github.com/lengsukq/lightisle/core/internal/tasks"
)

// trashRetention is a read-only view of the opt-in trash auto-cleanup
// policy. Only the Mac App may change it (private IPC), but every client
// needs the current policy to explain why trash entries disappear.
func (a *API) trashRetention(w http.ResponseWriter, _ *http.Request) {
	if a.retention == nil {
		jsonReply(w, 200, map[string]any{"enabled": false, "days": 0})
		return
	}
	value := a.retention.Get()
	jsonReply(w, 200, map[string]any{"enabled": value.Enabled, "days": value.Days})
}

var _ = tasks.MinRetentionDays
