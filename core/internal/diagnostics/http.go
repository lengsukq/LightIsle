package diagnostics

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type requestIDKey struct{}

func RequestID(ctx context.Context) string {
	id, _ := ctx.Value(requestIDKey{}).(string)
	return id
}

func HTTP(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		component, trace := requestComponent(r.URL.Path)
		if !trace {
			next.ServeHTTP(w, r)
			return
		}
		var token [16]byte
		_, _ = rand.Read(token[:])
		id := hex.EncodeToString(token[:])
		w.Header().Set("X-Request-ID", id)
		ctx := context.WithValue(r.Context(), requestIDKey{}, id)
		start := time.Now()
		response := &requestWriter{ResponseWriter: w, requestID: id}
		defer func() {
			operation := safeMethod(r.Method)
			event := Event{Component: component, Operation: operation, RequestID: id, ElapsedMS: time.Since(start).Milliseconds()}
			if failure := recover(); failure != nil {
				event.Code = "request_aborted"
				if failure != http.ErrAbortHandler {
					event.Code = "request_panic"
				}
				event.Status = response.status
				Emit(ctx, slog.LevelError, event)
				if response.status != 0 || failure == http.ErrAbortHandler {
					panic(http.ErrAbortHandler)
				}
				w.Header().Set("Content-Type", "application/json; charset=utf-8")
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"error":"internal_error"}`))
				return
			}
			event.Status = response.status
			if event.Status == 0 {
				event.Status = http.StatusOK
			}
			event.Code = response.code
			if event.Code == "" {
				event.Code = "http_" + strconv.Itoa(event.Status)
			}
			level := slog.LevelDebug
			if event.Status >= 400 && event.Status != http.StatusUnauthorized {
				level = slog.LevelWarn
			}
			Emit(ctx, level, event)
		}()
		next.ServeHTTP(response, r.WithContext(ctx))
	})
}

func requestComponent(path string) (string, bool) {
	if path == "/dav" || strings.HasPrefix(path, "/dav/") || strings.HasPrefix(path, "/dav-roots/") {
		return "webdav", true
	}
	relative, found := strings.CutPrefix(path, "/api/v2/")
	if !found {
		return "", false
	}
	head, tail, _ := strings.Cut(relative, "/")
	if head == "roots" && tail != "" {
		_, tail, _ = strings.Cut(tail, "/")
		head, _, _ = strings.Cut(tail, "/")
	}
	switch head {
	case "uploads", "downloads", "files", "photos", "cinema", "automation", "backup", "apps", "auth":
		return head, true
	case "users", "storage", "roots":
		return "storage", true
	default:
		return "api", true
	}
}

func safeMethod(method string) string {
	switch method {
	case "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS",
		"PROPFIND", "PROPPATCH", "LOCK", "UNLOCK", "MOVE", "COPY", "MKCOL":
		return strings.ToLower(method)
	default:
		return "request"
	}
}

type requestWriter struct {
	http.ResponseWriter
	status    int
	requestID string
	code      string
}

func (w *requestWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *requestWriter) WriteHeader(status int) {
	w.Header().Set("X-Request-ID", w.requestID)
	if w.status == 0 && (status >= 200 || status == http.StatusSwitchingProtocols) {
		w.status = status
	}
	w.ResponseWriter.WriteHeader(status)
}

// SetErrorCode accepts only known machine codes from the service. Other
// responses still have a request ID and an HTTP status in the log.
func SetErrorCode(w http.ResponseWriter, code string) {
	switch code {
	case "authentication_required", "admin_only", "file_permission_denied", "root_unavailable",
		"root_generation_changed", "volume_offline", "default_root_not_configured", "storage_quota_exceeded",
		"storage_accounting_conflict", "storage_accounting_uncertain", "storage_operation_uncertain",
		"offset_mismatch", "upload_outcome_uncertain", "upload_begin_uncertain", "insufficient_storage_space",
		"dav_unauthorized", "share_root_offline", "dav_remount_required", "dav_mount_not_found",
		"dav_replace_unsupported_save_as", "dav_invalid_destination", "dav_copy_unavailable",
		"dav_destination_exists", "download_permission_revoked", "download_unavailable", "transcode_unavailable":
	default:
		return
	}
	for w != nil {
		if tracked, ok := w.(*requestWriter); ok {
			tracked.code = code
			return
		}
		outer, ok := w.(interface{ Unwrap() http.ResponseWriter })
		if !ok {
			return
		}
		w = outer.Unwrap()
	}
}

func (w *requestWriter) Write(data []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(data)
}

func (w *requestWriter) FlushError() error {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	return http.NewResponseController(w.ResponseWriter).Flush()
}

func (w *requestWriter) Flush() { _ = w.FlushError() }

func (w *requestWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	conn, buffer, err := http.NewResponseController(w.ResponseWriter).Hijack()
	if err == nil && w.status == 0 {
		w.status = http.StatusSwitchingProtocols
	}
	return conn, buffer, err
}
