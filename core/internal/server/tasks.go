package server

import (
	"net/http"
)

// Task center summarizes existing backend jobs without exposing native-only
// backup control actions on the public HTTP service.
func (a *API) taskList(w http.ResponseWriter, r *http.Request) {
	if a.journal != nil {
		stored, err := a.journal.List()
		if err != nil {
			jsonReply(w, 503, map[string]string{"error": "task_journal_unavailable"})
			return
		}
		result := make([]map[string]any, 0, len(stored))
		for _, task := range stored {
			result = append(result, map[string]any{
				"kind": task.Kind, "operation": task.Operation, "running": task.Running,
				"progress": task.Processed, "bytes": task.Bytes, "lastDone": task.LastDone,
				"lastError": task.LastError, "startedAt": task.StartedAt, "attempts": task.Attempts,
			})
		}
		jsonReply(w, 200, map[string]any{"tasks": result})
		return
	}
	tasks := make([]map[string]any, 0, 3)
	if a.gallery != nil {
		st := a.gallery.Status()
		tasks = append(tasks, map[string]any{"kind": "gallery", "running": st.Running, "progress": st.Scanned, "found": st.Found, "lastDone": st.LastDone, "lastError": st.LastError})
	}
	if a.cinema != nil {
		st := a.cinema.Status()
		tasks = append(tasks, map[string]any{"kind": "cinema", "running": st.Running, "progress": st.Visited, "found": st.Found, "lastDone": st.LastDone, "lastError": st.LastError})
	}
	if a.backup != nil {
		st := a.backup.Status()
		tasks = append(tasks, map[string]any{"kind": "backup", "running": st.Running, "progress": st.Files, "bytes": st.Bytes, "lastDone": st.LastDone, "lastError": st.LastError, "operation": st.Operation})
	}
	jsonReply(w, 200, map[string]any{"tasks": tasks})
}
func (a *API) taskCancel(w http.ResponseWriter, r *http.Request) {
	var cancelled bool
	switch r.PathValue("kind") {
	case "gallery":
		if a.gallery != nil {
			cancelled = a.gallery.CancelScan()
		}
	case "cinema":
		if a.cinema != nil {
			cancelled = a.cinema.CancelScan()
		}
	default:
		jsonReply(w, 403, map[string]string{"error": "native_only_or_unknown_task"})
		return
	}
	if !cancelled {
		jsonReply(w, 409, map[string]string{"error": "task_not_running"})
		return
	}
	jsonReply(w, 200, map[string]bool{"cancelRequested": true})
}
func (a *API) taskRetry(w http.ResponseWriter, r *http.Request) {
	var err error
	switch r.PathValue("kind") {
	case "gallery":
		if a.gallery == nil {
			jsonReply(w, 503, map[string]string{"error": "gallery_unavailable"})
			return
		}
		err = a.gallery.StartScan()
	case "cinema":
		if a.cinema == nil {
			jsonReply(w, 503, map[string]string{"error": "cinema_unavailable"})
			return
		}
		err = a.cinema.StartScan()
	default:
		jsonReply(w, 403, map[string]string{"error": "native_only_or_unknown_task"})
		return
	}
	if err != nil {
		jsonReply(w, 409, map[string]string{"error": err.Error()})
		return
	}
	jsonReply(w, 202, map[string]bool{"started": true})
}
