package server

import (
	"net/http"
	"strconv"
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

func (a *API) taskHistory(w http.ResponseWriter, r *http.Request) {
	if a.journal == nil {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "task_history_unavailable"})
		return
	}
	limit := 20
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > 100 {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_page_size"})
			return
		}
		limit = parsed
	}
	var before int64
	if raw := r.URL.Query().Get("before"); raw != "" {
		parsed, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || parsed < 1 {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_cursor"})
			return
		}
		before = parsed
	}
	kind := r.URL.Query().Get("kind")
	if kind != "" && kind != "gallery" && kind != "cinema" && kind != "backup" && kind != "trash" {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_task_kind"})
		return
	}
	runs, next, err := a.journal.History(kind, before, limit)
	if err != nil {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "task_history_unavailable"})
		return
	}
	nextCursor := ""
	if next > 0 {
		nextCursor = strconv.FormatInt(next, 10)
	}
	jsonReply(w, http.StatusOK, map[string]any{"runs": runs, "nextCursor": nextCursor})
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
		if a.rootID != "" {
			err = a.startRootScan("gallery")
		} else {
			err = a.gallery.StartScan()
		}
	case "cinema":
		if a.cinema == nil {
			jsonReply(w, 503, map[string]string{"error": "cinema_unavailable"})
			return
		}
		if a.rootID != "" {
			err = a.startRootScan("cinema")
		} else {
			err = a.cinema.StartScan()
		}
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
