package server

import (
	"bytes"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

type failedDownloadWriter struct{ *httptest.ResponseRecorder }

func (w failedDownloadWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestPublicShareAuditReflectsResponseWithoutBearerOrPath(t *testing.T) {
	dir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	store, err := files.Open(filepath.Join(dir, "SharedFiles"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, err := store.Upload("private-name.txt", strings.NewReader("download bytes")); err != nil {
		t.Fatal(err)
	}
	f, info, err := store.Read("private-name.txt")
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	identity, ok := fileFingerprint(info)
	if !ok {
		t.Fatal("file identity unavailable")
	}
	_, capability, err := accounts.CreateFileShare(admin, "private-name.txt", identity, auth.ShareKindFile, 1, auth.SharePolicy{})
	if err != nil {
		t.Fatal(err)
	}
	handler := New("", accounts, store)
	for _, tc := range []struct {
		name, rangeHeader, outcome string
		failWrite                  bool
	}{
		{"download", "", "success", false},
		{"rejected range", "bytes=999-1000", "denied", false},
		{"broken connection", "", "failed", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, "/api/v1/public/file/"+capability, nil)
			if tc.rangeHeader != "" {
				r.Header.Set("Range", tc.rangeHeader)
			}
			var writer http.ResponseWriter = httptest.NewRecorder()
			if tc.failWrite {
				writer = failedDownloadWriter{httptest.NewRecorder()}
			}
			handler.ServeHTTP(writer, r)
			rows, _, err := accounts.ListAudit(admin, 0, 10)
			if err != nil || len(rows) == 0 {
				t.Fatalf("missing audit: %+v %v", rows, err)
			}
			row := rows[0]
			if row.Action != "public_share_download" || row.Target != "shared_file" || row.Outcome != tc.outcome {
				t.Fatalf("incorrect response audit: %+v", row)
			}
		})
	}
	before, _, _ := accounts.ListAudit(admin, 0, 10)
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodHead, "/api/v1/public/file/"+capability, nil))
	after, _, _ := accounts.ListAudit(admin, 0, 10)
	if len(before) != 3 || len(after) != len(before) {
		t.Fatalf("HEAD created download audit: %+v", after)
	}
}

func TestAuditPersistenceFailureEmitsWarning(t *testing.T) {
	store, err := auth.Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	store.Close()
	var output bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&output, nil)))
	defer slog.SetDefault(previous)
	(&API{auth: store}).recordAudit(1, "public_share_download", "shared_file", "success")
	if !strings.Contains(output.String(), "level=WARN") || !strings.Contains(output.String(), "audit record persist failed") {
		t.Fatalf("audit failure was silent: %s", output.String())
	}
}
