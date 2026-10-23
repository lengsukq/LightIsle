package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestFileSHA256RequiresACLAndChecksExactBytes(t *testing.T) {
	dir := t.TempDir()
	account, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer account.Close()
	store, err := files.Open(filepath.Join(dir, "SharedFiles"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err = account.Setup("owner", "strong-password-owner"); err != nil {
		t.Fatal(err)
	}
	owner, err := account.Login("owner", "strong-password-owner")
	if err != nil {
		t.Fatal(err)
	}
	member, err := account.CreateUser(owner, "member", "strong-password-member", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	user, err := account.Login("member", "strong-password-member")
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"Photos", "private"} {
		if err = store.Mkdir(p); err != nil {
			t.Fatal(err)
		}
	}
	content := []byte("backup-photo-contents-原始字节")
	if _, err = store.Upload("Photos/image.jpg", bytes.NewReader(content)); err != nil {
		t.Fatal(err)
	}
	if _, err = store.Upload("private/secret.jpg", strings.NewReader("classified")); err != nil {
		t.Fatal(err)
	}
	if err = account.SetFileGrant(owner, member.ID, "Photos", false); err != nil {
		t.Fatal(err)
	}
	handler := New("", account, store)
	request := func(raw, session string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, raw, nil)
		if session != "" {
			req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		res := httptest.NewRecorder()
		handler.ServeHTTP(res, req)
		return res
	}
	for _, tc := range []struct {
		url, session string
		code         int
	}{
		{"/api/v1/files/sha256?path=Photos/image.jpg", "", 401},
		{"/api/v1/files/sha256?path=private/secret.jpg", user, 403},
		{"/api/v1/files/sha256?path=Photos/missing.jpg", user, 404},
		{"/api/v1/files/sha256?path=../accounts.sqlite", owner, 403},
	} {
		got := request(tc.url, tc.session)
		if got.Code != tc.code {
			t.Fatalf("GET %s = %d, want %d: %s", tc.url, got.Code, tc.code, got.Body.String())
		}
	}
	good := request("/api/v1/files/sha256?path=Photos/image.jpg", user)
	if good.Code != 200 {
		t.Fatalf("hash %d %s", good.Code, good.Body.String())
	}
	var body struct {
		Algorithm string `json:"algorithm"`
		SHA256    string `json:"sha256"`
		Size      int64  `json:"size"`
	}
	if err = json.Unmarshal(good.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(content)
	if body.Algorithm != "sha256" || body.SHA256 != hex.EncodeToString(hash[:]) || body.Size != int64(len(content)) {
		t.Fatalf("wrong verification response: %+v", body)
	}
	// An ACL-preserving symlink may still point into another user's folder.
	if err = os.Symlink("../private/secret.jpg", filepath.Join(dir, "SharedFiles", "Photos", "alias.jpg")); err != nil {
		t.Fatal(err)
	}
	if res := request("/api/v1/files/sha256?path=Photos/alias.jpg", user); res.Code == 200 {
		t.Fatalf("symlink escaped allowed photos: %s", res.Body.String())
	}
	// Sparse fixture: reject the oversized file immediately without hashing
	// terabytes or allocating its declared storage size.
	large, err := os.OpenFile(filepath.Join(dir, "SharedFiles", "Photos", "oversized.jpg"), os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if err := large.Truncate(maxVerifiedFileBytes + 1); err != nil {
		large.Close()
		t.Fatal(err)
	}
	if err := large.Close(); err != nil {
		t.Fatal(err)
	}
	if got := request("/api/v1/files/sha256?path=Photos/oversized.jpg", user); got.Code != 413 {
		t.Fatalf("oversized photo hashing must fail before CPU-intensive reads: %d %s", got.Code, got.Body.String())
	}
	if err = account.SetEnabled(owner, member.ID, false); err != nil {
		t.Fatal(err)
	}
	if got := request("/api/v1/files/sha256?path=Photos/image.jpg", user); got.Code != 401 {
		t.Fatalf("revoked account can still query remote content hashes: %d", got.Code)
	}
}

type hashTestAccess struct {
	files.Access
	read func(string) (*os.File, os.FileInfo, error)
}

func (a hashTestAccess) Read(p string) (*os.File, os.FileInfo, error) { return a.read(p) }

type hashTestInfo struct {
	os.FileInfo
	size int64
}

func (i hashTestInfo) Size() int64 { return i.size }

func newHashTestAPI(t *testing.T) (*API, string, string) {
	t.Helper()
	dir := t.TempDir()
	account, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { account.Close() })
	if err := account.Setup("owner", "strong-password-owner"); err != nil {
		t.Fatal(err)
	}
	session, err := account.Login("owner", "strong-password-owner")
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(dir, "share")
	store, err := files.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	if _, err := store.Upload("photo.jpg", strings.NewReader("photo bytes")); err != nil {
		t.Fatal(err)
	}
	return &API{auth: account, files: store, fileHashSlots: make(chan struct{}, 2)}, session, root
}
func hashTestRequest(ctx context.Context, session string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/api/v1/files/sha256?path=photo.jpg", nil).WithContext(ctx)
	r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
	return r
}

func TestFileSHA256SharesBudgetAndReleasesCanceledRequests(t *testing.T) {
	api, session, _ := newHashTestAPI(t)
	original := api.files
	entered, release := make(chan struct{}, 2), make(chan struct{})
	api.files = hashTestAccess{Access: original, read: func(p string) (*os.File, os.FileInfo, error) {
		entered <- struct{}{}
		<-release
		return original.Read(p)
	}}
	// Copies represent separate root APIs sharing the same process budget.
	anotherRoot := *api
	var wg sync.WaitGroup
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	for _, a := range []*API{api, &anotherRoot} {
		wg.Add(1)
		go func(a *API) { defer wg.Done(); a.fileSHA256(httptest.NewRecorder(), hashTestRequest(ctx, session)) }(a)
	}
	for range 2 {
		select {
		case <-entered:
		case <-time.After(5 * time.Second):
			close(release)
			t.Fatal("hash failed to enter file read")
		}
	}
	busy := httptest.NewRecorder()
	anotherRoot.fileSHA256(busy, hashTestRequest(context.Background(), session))
	if busy.Code != http.StatusTooManyRequests || busy.Header().Get("Retry-After") != "1" || !strings.Contains(busy.Body.String(), "file_hash_busy") {
		cancel()
		close(release)
		wg.Wait()
		t.Fatalf("expected bounded busy response, got %d %s", busy.Code, busy.Body.String())
	}
	cancel()
	close(release)
	wg.Wait()
	if len(api.fileHashSlots) != 0 {
		t.Fatal("canceled requests leaked hash budget")
	}
	api.files = original
	good := httptest.NewRecorder()
	api.fileSHA256(good, hashTestRequest(context.Background(), session))
	if good.Code != 200 {
		t.Fatalf("hash after cancellation: %d %s", good.Code, good.Body.String())
	}
}

func TestFileSHA256StopsReadingWhenFileGrows(t *testing.T) {
	api, session, root := newHashTestAPI(t)
	if err := os.WriteFile(filepath.Join(root, "photo.jpg"), bytes.Repeat([]byte("x"), 1<<20), 0600); err != nil {
		t.Fatal(err)
	}
	original := api.files
	var observed *os.File
	api.files = hashTestAccess{Access: original, read: func(p string) (*os.File, os.FileInfo, error) {
		f, info, err := original.Read(p)
		if err != nil {
			return f, info, err
		}
		// A duplicated descriptor observes the shared read offset after the handler
		// closes its descriptor. Model growth after a one-byte initial stat.
		fd, err := syscall.Dup(int(f.Fd()))
		if err != nil {
			f.Close()
			return nil, nil, err
		}
		observed = os.NewFile(uintptr(fd), "observed-photo")
		return f, hashTestInfo{FileInfo: info, size: 1}, nil
	}}
	res := httptest.NewRecorder()
	api.fileSHA256(res, hashTestRequest(context.Background(), session))
	if observed == nil {
		t.Fatal("file not opened")
	}
	defer observed.Close()
	offset, err := observed.Seek(0, 1)
	if err != nil {
		t.Fatal(err)
	}
	if res.Code != 409 || offset != 2 {
		t.Fatalf("growing file: status=%d bytes=%d body=%s", res.Code, offset, res.Body.String())
	}
	if len(api.fileHashSlots) != 0 {
		t.Fatal("changed file leaked hash budget")
	}
}

func TestFileSHA256RejectsOversizeBeforeReading(t *testing.T) {
	api, session, root := newHashTestAPI(t)
	f, err := os.OpenFile(filepath.Join(root, "photo.jpg"), os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	// Sparse file exercises the limit without allocating a multi-gigabyte body.
	err = f.Truncate(maxVerifiedFileBytes + 1)
	f.Close()
	if err != nil {
		t.Fatal(err)
	}
	res := httptest.NewRecorder()
	api.fileSHA256(res, hashTestRequest(context.Background(), session))
	if res.Code != 413 || !strings.Contains(res.Body.String(), "verification_size_limit") {
		t.Fatalf("oversize file: %d %s", res.Code, res.Body.String())
	}
	if len(api.fileHashSlots) != 0 {
		t.Fatal("oversize file leaked hash budget")
	}
}
