package server

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestFileAPIDeniesCaseAliasesOfInternalPaths(t *testing.T) {
	f := newFolderShareFixture(t)
	for _, path := range []string{".LIGHTISLE-TRASH/entry", "visible/.LightIsle-journal"} {
		got := f.call(http.MethodGet, "/api/v2/files/content?path="+path, "", f.admin)
		if got.Code != http.StatusForbidden || !strings.Contains(got.Body.String(), "file_permission_denied") {
			t.Fatalf("internal alias %q reached filesystem lookup: %d %s", path, got.Code, got.Body.String())
		}
	}
}

func TestStaticAssetsCannotFollowLinksOutsideWebRoot(t *testing.T) {
	assets := t.TempDir()
	secret := filepath.Join(t.TempDir(), "private.txt")
	if err := os.WriteFile(secret, []byte("private bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(assets, "index.html"), []byte("app shell"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(secret, filepath.Join(assets, "leak.txt")); err != nil {
		t.Fatal(err)
	}
	handler := New(assets, nil, nil)
	for path, expected := range map[string]int{"/leak.txt": http.StatusNotFound, "/settings": http.StatusOK} {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != expected || strings.Contains(rec.Body.String(), "private bytes") {
			t.Fatalf("%s: %d %s", path, rec.Code, rec.Body.String())
		}
	}
}

func TestPasswordWorkSaturationKeepsAttemptBudget(t *testing.T) {
	f := newFolderShareFixture(t)
	for i := 0; i < cap(passwordWorkSlots); i++ {
		if !tryPasswordWork() {
			t.Fatal("password slot unexpectedly busy")
		}
	}
	login := func() *httptest.ResponseRecorder {
		return f.call(http.MethodPost, "/api/v2/auth/login", `{"username":"owner","password":"owner-password-12345"}`, nil)
	}
	func() {
		defer func() {
			for i := 0; i < cap(passwordWorkSlots); i++ {
				<-passwordWorkSlots
			}
		}()
		for i := 0; i < loginRemoteAttemptLimit; i++ {
			got := login()
			if got.Code != http.StatusServiceUnavailable || got.Header().Get("Retry-After") == "" {
				t.Fatalf("busy login returned %d %s", got.Code, got.Body.String())
			}
		}
	}()
	if got := login(); got.Code != http.StatusOK {
		t.Fatalf("busy attempts locked out a valid login: %d %s", got.Code, got.Body.String())
	}
}

func TestDownloadCreateRequiresAdminEvenWithWriteGrant(t *testing.T) {
	f := newFolderShareFixture(t)
	member, err := f.accounts.CreateUser(f.admin.Value, "member", "member-password-12345", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.accounts.SetFileGrant(f.admin.Value, member.ID, ".", true); err != nil {
		t.Fatal(err)
	}
	cookie := f.login("member", "member-password-12345")
	got := f.call(http.MethodPost, "/api/v2/downloads", `{"url":"http://127.0.0.1/private","destination":"."}`, cookie)
	if got.Code != http.StatusForbidden || !strings.Contains(got.Body.String(), "admin_only") {
		t.Fatalf("member reached network download handler: %d %s", got.Code, got.Body.String())
	}
}

func TestLegacyPublicShareCannotExposePrivateHomes(t *testing.T) {
	f := newFolderShareFixture(t)
	for _, name := range []string{"Users", "Users/u1", "Users/u1/files"} {
		if err := f.store.Mkdir(name); err != nil {
			t.Fatal(err)
		}
	}
	name := "Users/u1/files"
	info, err := f.store.Stat(name)
	if err != nil {
		t.Fatal(err)
	}
	identity, ok := dirFingerprint(info)
	if !ok {
		t.Fatal("missing directory fingerprint")
	}
	// Seed a capability directly, as if issued before legacy access to the
	// reserved namespace was prohibited.
	_, capability, err := f.accounts.CreateFileShare(f.admin.Value, name, identity, auth.ShareKindDir, 1, auth.SharePolicy{})
	if err != nil {
		t.Fatal(err)
	}
	got := f.call(http.MethodHead, "/api/v2/public/file/"+capability, "", nil)
	if got.Code != http.StatusNotFound {
		t.Fatalf("legacy share exposed private storage: %d", got.Code)
	}
}

func TestLoginOnlyAcceptsHTTPSForwardingFromLoopback(t *testing.T) {
	f := newFolderShareFixture(t)
	for _, tc := range []struct {
		remote string
		proto  []string
		secure bool
	}{
		{"127.0.0.1:1234", []string{"https"}, true},
		{"127.0.0.1:1234", []string{"https", "http"}, false},
		{"192.168.1.4:1234", []string{"https"}, false},
	} {
		req := httptest.NewRequest(http.MethodPost, "/api/v2/auth/login",
			strings.NewReader(`{"username":"owner","password":"owner-password-12345"}`))
		req.RemoteAddr = tc.remote
		req.Header.Set("X-LightIsle-Request", "1")
		for _, value := range tc.proto {
			req.Header.Add("X-Forwarded-Proto", value)
		}
		got := httptest.NewRecorder()
		f.handler.ServeHTTP(got, req)
		cookies := got.Result().Cookies()
		if got.Code != http.StatusOK || len(cookies) != 1 || cookies[0].Secure != tc.secure {
			t.Fatalf("unexpected cookie flags for %s via %v: status=%d", tc.remote, tc.proto, got.Code)
		}
	}
}

type timedOutUploadReader struct{}

func (timedOutUploadReader) Read([]byte) (int, error) { return 0, os.ErrDeadlineExceeded }

func TestTimedOutUploadChunkCanResumeAtCommittedOffset(t *testing.T) {
	f := newFolderShareFixture(t)
	begin := f.call(http.MethodPost, "/api/v2/uploads", `{"path":"resume.txt","size":4}`, f.admin)
	var state files.UploadState
	if begin.Code != http.StatusCreated || json.Unmarshal(begin.Body.Bytes(), &state) != nil {
		t.Fatalf("begin: %d %s", begin.Code, begin.Body.String())
	}
	call := func(body io.Reader) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPatch, "/api/v2/uploads/"+state.ID, body)
		req.ContentLength = 4
		req.Header.Set("X-LightIsle-Request", "1")
		req.Header.Set("X-Upload-Offset", "0")
		req.AddCookie(f.admin)
		got := httptest.NewRecorder()
		f.handler.ServeHTTP(got, req)
		return got
	}
	got := call(io.MultiReader(strings.NewReader("ab"), timedOutUploadReader{}))
	if got.Code != http.StatusRequestTimeout || !strings.Contains(got.Body.String(), "upload_timed_out") {
		t.Fatalf("timeout: %d %s", got.Code, got.Body.String())
	}
	got = call(strings.NewReader("abcd"))
	var completed files.UploadState
	if got.Code != http.StatusOK || json.Unmarshal(got.Body.Bytes(), &completed) != nil || completed.Offset != 4 {
		t.Fatalf("retry at original offset: %d %s", got.Code, got.Body.String())
	}
}
