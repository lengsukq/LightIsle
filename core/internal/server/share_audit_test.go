package server

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

type failedDownloadWriter struct{ *httptest.ResponseRecorder }

func (w failedDownloadWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestPublicShareAuditReflectsResponseWithoutBearerOrPath(t *testing.T) {
	f := newRootRoutingFixture(t)
	filePath := filepath.Join(f.pathA, "private-name.txt")
	if err := os.WriteFile(filePath, []byte("download bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	created := f.call(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/file-shares"), `{"path":"private-name.txt","hours":1}`)
	if created.Code != http.StatusCreated {
		t.Fatalf("create share: %d %s", created.Code, created.Body.String())
	}
	var resp struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(created.Body.Bytes(), &resp); err != nil || resp.Token == "" {
		t.Fatalf("share response: %v %s", err, created.Body.String())
	}
	capability := resp.Token
	link := rootRoute(f.rootA.ID, "/public/file/"+capability)
	baseEvents, _, _ := f.accounts.ListAudit(f.admin, 0, 20)
	baseCount := len(baseEvents)
	for _, tc := range []struct {
		name, rangeHeader, outcome string
		failWrite                  bool
	}{
		{"download", "", "success", false},
		{"rejected range", "bytes=999-1000", "denied", false},
		{"broken connection", "", "failed", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, link, nil)
			if tc.rangeHeader != "" {
				r.Header.Set("Range", tc.rangeHeader)
			}
			var writer http.ResponseWriter = httptest.NewRecorder()
			if tc.failWrite {
				writer = failedDownloadWriter{httptest.NewRecorder()}
			}
			f.server.ServeHTTP(writer, r)
			rows, _, err := f.accounts.ListAudit(f.admin, 0, 10)
			if err != nil || len(rows) == 0 {
				t.Fatalf("missing audit: %+v %v", rows, err)
			}
			row := rows[0]
			if row.Action != "public_share_download" || row.Target != "shared_file" || row.Outcome != tc.outcome {
				t.Fatalf("incorrect response audit: %+v", row)
			}
		})
	}
	before, _, _ := f.accounts.ListAudit(f.admin, 0, 20)
	f.server.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodHead, link, nil))
	after, _, _ := f.accounts.ListAudit(f.admin, 0, 20)
	if len(before) != baseCount+3 || len(after) != len(before) {
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
