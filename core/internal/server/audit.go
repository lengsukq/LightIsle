package server

import (
	"log/slog"
	"net/http"
	"strconv"
	"strings"
)

type auditWriter struct {
	http.ResponseWriter
	status   int
	writeErr error
}

func (w *auditWriter) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	if status >= 200 {
		w.status = status
	}
	w.ResponseWriter.WriteHeader(status)
}
func (w *auditWriter) Write(data []byte) (int, error) {
	if w.status == 0 {
		w.status = 200
	}
	n, err := w.ResponseWriter.Write(data)
	if err != nil {
		w.writeErr = err
	}
	return n, err
}

func (w *auditWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func auditOutcome(status int) string {
	if status >= 500 {
		return "failed"
	}
	if status >= 400 {
		return "denied"
	}
	return "success"
}

func (a *API) recordAudit(actorID int64, action, target, outcome string) {
	if err := a.auth.AppendAudit(actorID, action, target, outcome); err != nil {
		slog.Warn("audit record persist failed", "action", action, "error", err)
	}
}

func auditedAction(r *http.Request) string {
	if r.Method == "GET" || r.Method == "HEAD" || r.Method == "OPTIONS" {
		return ""
	}
	p := r.URL.Path
	switch {
	case strings.HasPrefix(p, "/api/v2/roots/") && strings.Contains(p, "/users/") && strings.Contains(p, "/file-grants"):
		return "root_grant_change"
	case strings.HasPrefix(p, "/api/v2/roots/") && strings.Contains(p, "/file-shares"):
		return "root_file_share_change"
	case strings.HasPrefix(p, "/api/v2/roots/") && strings.Contains(p, "/files"):
		return "root_file_write"
	case strings.HasPrefix(p, "/api/v2/roots/") && strings.Contains(p, "/uploads"):
		return "root_upload_write"
	case strings.HasPrefix(p, "/api/v2/roots/") && strings.Contains(p, "/photos"):
		return "root_gallery_write"
	case strings.HasPrefix(p, "/api/v2/roots/") && strings.Contains(p, "/cinema"):
		return "root_cinema_write"
	case strings.HasPrefix(p, "/api/v2/roots/") && strings.Contains(p, "/alerts"):
		return "root_alert_acknowledge"
	case p == "/api/v1/auth/password":
		return "account_password_change"
	case strings.HasPrefix(p, "/api/v1/users"):
		return "user_or_grant_change"
	case strings.HasPrefix(p, "/api/v1/file-shares"):
		return "file_share_change"
	case strings.HasPrefix(p, "/api/v1/files"):
		return "file_write"
	case strings.HasPrefix(p, "/api/v1/uploads"):
		return "upload_write"
	case strings.HasPrefix(p, "/api/v1/photos"):
		return "gallery_write"
	case strings.HasPrefix(p, "/api/v1/cinema"):
		return "cinema_write"
	case strings.HasPrefix(p, "/api/v1/alerts"):
		return "alert_acknowledge"
	default:
		return ""
	}
}

// Audit wraps only authenticated mutation routes, never media downloads or
// their possibly sensitive query strings. Log route PATTERNS (not URLs) so
// file names, share secrets, passwords and payloads are never persisted.
func (a *API) auditMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		action := auditedAction(r)
		if action == "" || a.auth == nil {
			next.ServeHTTP(w, r)
			return
		}
		actor, ok := a.auth.Identity(token(r))
		if !ok {
			next.ServeHTTP(w, r)
			return
		}
		tracked := &auditWriter{ResponseWriter: w}
		next.ServeHTTP(tracked, r)
		target := r.Pattern
		if target == "" {
			target = "unknown_route"
		}
		outcome := auditOutcome(tracked.status)
		if tracked.writeErr != nil {
			outcome = "failed"
		}
		a.recordAudit(actor.ID, action, target, outcome)
	})
}

func (a *API) auditHistory(w http.ResponseWriter, r *http.Request) {
	limit := 50
	if raw := r.URL.Query().Get("limit"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value < 1 || value > 100 {
			jsonReply(w, 400, map[string]string{"error": "invalid_limit"})
			return
		}
		limit = value
	}
	before, err := strconv.ParseInt(r.URL.Query().Get("before"), 10, 64)
	if r.URL.Query().Get("before") != "" && (err != nil || before <= 0) {
		jsonReply(w, 400, map[string]string{"error": "invalid_cursor"})
		return
	}
	events, next, err := a.auth.ListAudit(token(r), before, limit)
	if err != nil {
		jsonReply(w, 503, map[string]string{"error": "audit_unavailable"})
		return
	}
	jsonReply(w, 200, map[string]any{"events": events, "nextCursor": next})
}
