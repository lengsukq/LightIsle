package server

import (
	"net/http"

	"github.com/lengsukq/lightisle/core/internal/tasks"
)

// Legacy app-trash automatic deletion is suspended during the transition to
// the system Trash. Report the effective state, even if an older preference
// remains on disk, so clients never promise a cleanup that cannot run.
func (a *API) trashRetention(w http.ResponseWriter, _ *http.Request) {
	if a.retention == nil {
		jsonReply(w, 200, map[string]any{"enabled": false, "days": 0})
		return
	}
	value := a.retention.Get()
	jsonReply(w, 200, map[string]any{"enabled": false, "days": value.Days})
}

var _ = tasks.MinRetentionDays
