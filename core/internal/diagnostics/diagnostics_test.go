package diagnostics

import (
	"bytes"
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHTTPDiagnosticCorrelatesFailureWithoutRequestData(t *testing.T) {
	dir := t.TempDir()
	logger := Start(dir)
	defer logger.Close()
	previous := slog.Default()
	slog.SetDefault(slog.New(logger.Handler()))
	defer slog.SetDefault(previous)

	handler := HTTP(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if RequestID(r.Context()) != w.Header().Get("X-Request-ID") {
			t.Error("missing request ID in operation")
		}
		slog.Warn("arbitrary-secret-message", "error", "/private/secret", "authorization", "secret-password")
		w.WriteHeader(http.StatusConflict)
	}))
	request := httptest.NewRequest(http.MethodPut, "/dav/secret-filename?token=secret-share", strings.NewReader("secret-body"))
	request.Header.Set("X-Request-ID", "forged-request-id")
	request.SetBasicAuth("secret-member", "secret-password")
	result := httptest.NewRecorder()
	handler.ServeHTTP(result, request)
	id := result.Header().Get("X-Request-ID")
	if result.Code != http.StatusConflict || len(id) != 32 {
		t.Fatalf("unexpected result %d %q", result.Code, id)
	}
	logger.Close()
	data, err := os.ReadFile(filepath.Join(dir, "diagnostics", "core", "events-0.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte("secret")) || bytes.Contains(data, []byte("forged")) ||
		!bytes.Contains(data, []byte(id)) || !bytes.Contains(data, []byte("http_409")) {
		t.Fatalf("log redaction or correlation failed: %s", data)
	}
}

func TestHTTPDiagnosticRecordsDAVErrorCodesAndComponent(t *testing.T) {
	dir := t.TempDir()
	logger := Start(dir)
	defer logger.Close()
	previous := slog.Default()
	slog.SetDefault(slog.New(logger.Handler()))
	defer slog.SetDefault(previous)
	handler := HTTP(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		SetErrorCode(w, "dav_cross_owner_move")
		w.WriteHeader(http.StatusForbidden)
	}))
	request := httptest.NewRequest("MOVE", "/dav-roots/0123456789abcdef0123456789abcdef/1/Users/u1/files/a.txt", nil)
	result := httptest.NewRecorder()
	handler.ServeHTTP(result, request)
	logger.Close()
	data, err := os.ReadFile(filepath.Join(dir, "diagnostics", "core", "events-0.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(data, []byte(`"component":"webdav"`)) || !bytes.Contains(data, []byte(`"code":"dav_cross_owner_move"`)) {
		t.Fatalf("expected webdav component and dav_cross_owner_move code in %s", data)
	}
}

func TestLogRotatesAndRejectsSymlink(t *testing.T) {
	data := t.TempDir()
	dir := filepath.Join(data, "diagnostics", "core")
	file, _, err := openLog(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(maxLogBytes); err != nil {
		t.Fatal(err)
	}
	_ = file.Close()
	logger := Start(data)
	slog.New(logger.Handler()).Log(context.Background(), slog.LevelError, "test")
	logger.Close()
	old, err := os.Stat(logName(dir, 1))
	if err != nil || old.Size() != maxLogBytes {
		t.Fatalf("missing rotated log: %v %v", old, err)
	}
	if err := os.Remove(logName(dir, 0)); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(logName(dir, 1), logName(dir, 0)); err != nil {
		t.Fatal(err)
	}
	if handle, _, err := openLog(dir); err == nil {
		_ = handle.Close()
		t.Fatal("opened a symlink as active log")
	}
}
