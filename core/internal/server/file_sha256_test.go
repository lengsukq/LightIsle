package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
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
		{"/api/v1/files/sha256?path=Photos/image.jpg&mode=range&offset=0&length=1", "", 401},
		{"/api/v1/files/sha256?path=private/secret.jpg", user, 403},
		{"/api/v1/files/sha256?path=private/secret.jpg&mode=range&offset=0&length=1", user, 403},
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

type hashTestTimespec struct {
	Sec  int64
	Nsec int64
}

type hashTestStat struct {
	Dev           uint64
	Ino           uint64
	Atim          hashTestTimespec
	Mtim          hashTestTimespec
	Ctim          hashTestTimespec
	Birthtimespec hashTestTimespec
	Gen           uint64
}

type hashVersionInfo struct {
	size    int64
	modTime time.Time
	mode    os.FileMode
	sys     any
}

func (i hashVersionInfo) Name() string       { return "hidden-name" }
func (i hashVersionInfo) Size() int64        { return i.size }
func (i hashVersionInfo) Mode() os.FileMode  { return i.mode }
func (i hashVersionInfo) ModTime() time.Time { return i.modTime }
func (i hashVersionInfo) IsDir() bool        { return i.mode.IsDir() }
func (i hashVersionInfo) Sys() any           { return i.sys }

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
	return hashTestRequestURL(ctx, session, "/api/v1/files/sha256?path=photo.jpg")
}

func hashTestRequestURL(ctx context.Context, session, url string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, url, nil).WithContext(ctx)
	r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
	return r
}

func withAPFSHashProbe(t *testing.T) {
	t.Helper()
	original := rangeFileSystemAPFSProbe
	rangeFileSystemAPFSProbe = func(*os.File) (bool, error) { return true, nil }
	t.Cleanup(func() { rangeFileSystemAPFSProbe = original })
}

func TestFileSHA256RangeReadsAuthorizedBoundedChunks(t *testing.T) {
	withAPFSHashProbe(t)
	api, session, root := newHashTestAPI(t)
	content := []byte("0123456789abcdef")
	if err := os.WriteFile(filepath.Join(root, "photo.jpg"), content, 0600); err != nil {
		t.Fatal(err)
	}
	request := func(offset, length int, version string) *httptest.ResponseRecorder {
		url := "/api/v1/files/sha256?path=photo.jpg&mode=range&offset=" + strconv.Itoa(offset) + "&length=" + strconv.Itoa(length)
		if version != "" {
			url += "&version=" + version
		}
		res := httptest.NewRecorder()
		api.fileSHA256(res, hashTestRequestURL(context.Background(), session, url))
		return res
	}
	type result struct {
		Algorithm string `json:"algorithm"`
		SHA256    string `json:"sha256"`
		Size      int64  `json:"size"`
		Offset    int64  `json:"offset"`
		Length    int64  `json:"length"`
		Version   string `json:"version"`
	}
	first := request(0, 8, "")
	if first.Code != http.StatusOK {
		t.Fatalf("first chunk: %d %s", first.Code, first.Body.String())
	}
	var firstResult result
	if err := json.Unmarshal(first.Body.Bytes(), &firstResult); err != nil {
		t.Fatal(err)
	}
	wantFirst := sha256.Sum256(content[:8])
	if firstResult.Algorithm != "sha256" || firstResult.SHA256 != hex.EncodeToString(wantFirst[:]) ||
		firstResult.Size != int64(len(content)) || firstResult.Offset != 0 || firstResult.Length != 8 ||
		!regexp.MustCompile(`^[a-f0-9]{64}$`).MatchString(firstResult.Version) || strings.Contains(firstResult.Version, "photo.jpg") {
		t.Fatalf("invalid range result: %+v", firstResult)
	}
	second := request(8, 8, firstResult.Version)
	if second.Code != http.StatusOK {
		t.Fatalf("second chunk: %d %s", second.Code, second.Body.String())
	}
	var secondResult result
	if err := json.Unmarshal(second.Body.Bytes(), &secondResult); err != nil {
		t.Fatal(err)
	}
	wantSecond := sha256.Sum256(content[8:])
	if secondResult.SHA256 != hex.EncodeToString(wantSecond[:]) || secondResult.Version != firstResult.Version ||
		secondResult.Offset != 8 || secondResult.Length != 8 || secondResult.Size != int64(len(content)) {
		t.Fatalf("invalid second range result: %+v", secondResult)
	}
	if got := request(8, 8, ""); got.Code != http.StatusBadRequest || !strings.Contains(got.Body.String(), "verification_version_required") {
		t.Fatalf("nonzero offset without version: %d %s", got.Code, got.Body.String())
	}
	if got := request(8, 8, strings.Repeat("0", 64)); got.Code != http.StatusConflict {
		t.Fatalf("stale version: %d %s", got.Code, got.Body.String())
	}
}

func TestFileSHA256RangeRejectsInvalidAndOversizedRequests(t *testing.T) {
	withAPFSHashProbe(t)
	api, session, root := newHashTestAPI(t)
	call := func(query string) *httptest.ResponseRecorder {
		res := httptest.NewRecorder()
		api.fileSHA256(res, hashTestRequestURL(context.Background(), session, "/api/v1/files/sha256?path=photo.jpg&mode=range&"+query))
		return res
	}
	for _, query := range []string{
		"offset=-1&length=1",
		"offset=0&length=0",
		"offset=0&length=4194305",
		"offset=9223372036854775807&length=2",
	} {
		if got := call(query); got.Code != http.StatusBadRequest && got.Code != http.StatusRequestedRangeNotSatisfiable {
			t.Errorf("invalid query %q: %d %s", query, got.Code, got.Body.String())
		}
	}
	unknownMode := httptest.NewRecorder()
	api.fileSHA256(unknownMode, hashTestRequestURL(context.Background(), session,
		"/api/v1/files/sha256?path=photo.jpg&mode=unknown"))
	if unknownMode.Code != http.StatusBadRequest {
		t.Fatalf("unknown mode: %d %s", unknownMode.Code, unknownMode.Body.String())
	}
	large, err := os.OpenFile(filepath.Join(root, "too-large.bin"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	err = large.Truncate(maxRangeVerifiedFileBytes + 1)
	if closeErr := large.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		t.Fatal(err)
	}
	res := httptest.NewRecorder()
	api.fileSHA256(res, hashTestRequestURL(context.Background(), session,
		"/api/v1/files/sha256?path=too-large.bin&mode=range&offset=0&length=1"))
	if res.Code != http.StatusRequestEntityTooLarge || !strings.Contains(res.Body.String(), "verification_size_limit") {
		t.Fatalf("oversized range target: %d %s", res.Code, res.Body.String())
	}
}

func TestFileSHA256RangeRejectsObjectReplacementAndCancellationReleasesBudget(t *testing.T) {
	withAPFSHashProbe(t)
	api, session, root := newHashTestAPI(t)
	first := httptest.NewRecorder()
	api.fileSHA256(first, hashTestRequestURL(context.Background(), session,
		"/api/v1/files/sha256?path=photo.jpg&mode=range&offset=0&length=2"))
	if first.Code != http.StatusOK {
		t.Fatalf("initial range: %d %s", first.Code, first.Body.String())
	}
	var body struct {
		Version string `json:"version"`
	}
	if err := json.Unmarshal(first.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	tmp := filepath.Join(root, "replacement.tmp")
	if err := os.WriteFile(tmp, []byte("replacement"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, filepath.Join(root, "photo.jpg")); err != nil {
		t.Fatal(err)
	}
	changed := httptest.NewRecorder()
	api.fileSHA256(changed, hashTestRequestURL(context.Background(), session,
		"/api/v1/files/sha256?path=photo.jpg&mode=range&offset=2&length=2&version="+body.Version))
	if changed.Code != http.StatusConflict {
		t.Fatalf("replacement object: %d %s", changed.Code, changed.Body.String())
	}

	original := api.files
	entered, release := make(chan struct{}, 1), make(chan struct{})
	api.files = hashTestAccess{Access: original, read: func(path string) (*os.File, os.FileInfo, error) {
		entered <- struct{}{}
		<-release
		return original.Read(path)
	}}
	ctx, cancel := context.WithCancel(context.Background())
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		api.fileSHA256(httptest.NewRecorder(), hashTestRequestURL(ctx, session,
			"/api/v1/files/sha256?path=photo.jpg&mode=range&offset=0&length=2"))
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		cancel()
		close(release)
		t.Fatal("range verification did not enter file read")
	}
	cancel()
	close(release)
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("canceled range verification did not finish")
	}
	if len(api.fileHashSlots) != 0 {
		t.Fatal("canceled range verification leaked hash budget")
	}
}

func TestFileSHA256RangeRejectsUnsupportedFilesystem(t *testing.T) {
	original := rangeFileSystemAPFSProbe
	rangeFileSystemAPFSProbe = func(*os.File) (bool, error) { return false, nil }
	t.Cleanup(func() { rangeFileSystemAPFSProbe = original })
	api, session, _ := newHashTestAPI(t)
	res := httptest.NewRecorder()
	api.fileSHA256(res, hashTestRequestURL(context.Background(), session,
		"/api/v1/files/sha256?path=photo.jpg&mode=range&offset=0&length=1"))
	if res.Code != http.StatusNotImplemented || !strings.Contains(res.Body.String(), "verification_filesystem_unsupported") {
		t.Fatalf("unsupported filesystem: %d %s", res.Code, res.Body.String())
	}
}

func TestFileSHA256RangeRechecksReadGrantBeforeResponse(t *testing.T) {
	withAPFSHashProbe(t)
	api, owner, _ := newHashTestAPI(t)
	member, err := api.auth.CreateUser(owner, "read-only", "secure-password-member", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	user, err := api.auth.Login("read-only", "secure-password-member")
	if err != nil {
		t.Fatal(err)
	}
	if err := api.auth.SetFileGrant(owner, member.ID, ".", false); err != nil {
		t.Fatal(err)
	}
	original := api.files
	entered, release := make(chan struct{}, 1), make(chan struct{})
	var once sync.Once
	api.files = hashTestAccess{Access: original, read: func(path string) (*os.File, os.FileInfo, error) {
		file, info, err := original.Read(path)
		if err == nil {
			once.Do(func() {
				entered <- struct{}{}
				<-release
			})
		}
		return file, info, err
	}}
	res := httptest.NewRecorder()
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		api.fileSHA256(res, hashTestRequestURL(context.Background(), user,
			"/api/v1/files/sha256?path=photo.jpg&mode=range&offset=0&length=2"))
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		close(release)
		t.Fatal("range request did not reach file read")
	}
	if err := api.auth.RemoveFileGrant(owner, member.ID, "."); err != nil {
		close(release)
		t.Fatal(err)
	}
	close(release)
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("range request did not finish after authorization revocation")
	}
	if res.Code != http.StatusForbidden || !strings.Contains(res.Body.String(), "file_permission_denied") ||
		strings.Contains(res.Body.String(), `"sha256"`) {
		t.Fatalf("revoked grant got successful hash: %d %s", res.Code, res.Body.String())
	}
}

func TestFileSHA256RangeCancellationBeforeHashReadWritesNoSuccessAndReleasesBudget(t *testing.T) {
	withAPFSHashProbe(t)
	api, session, _ := newHashTestAPI(t)
	original := api.files
	entered, release := make(chan struct{}, 1), make(chan struct{})
	api.files = hashTestAccess{Access: original, read: func(path string) (*os.File, os.FileInfo, error) {
		entered <- struct{}{}
		<-release
		return original.Read(path)
	}}
	ctx, cancel := context.WithCancel(context.Background())
	res := httptest.NewRecorder()
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		api.fileSHA256(res, hashTestRequestURL(ctx, session,
			"/api/v1/files/sha256?path=photo.jpg&mode=range&offset=0&length=2"))
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		cancel()
		close(release)
		t.Fatal("range request did not reach file read")
	}
	cancel()
	close(release)
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("canceled range request did not finish")
	}
	if res.Body.Len() != 0 {
		t.Fatalf("canceled request returned a response: %d %s", res.Code, res.Body.String())
	}
	if len(api.fileHashSlots) != 0 {
		t.Fatal("canceled range request leaked hash budget")
	}
}

type cancelAfterOneHashRead struct {
	cancel context.CancelFunc
	reads  int
}

func (r *cancelAfterOneHashRead) Read(target []byte) (int, error) {
	r.reads++
	if r.reads == 1 {
		target[0] = 'x'
		r.cancel()
		return 1, nil
	}
	return 0, io.EOF
}

func TestContextHashReaderStopsAfterCancellationWithinRead(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	reader := &cancelAfterOneHashRead{cancel: cancel}
	_, err := io.CopyBuffer(sha256.New(), contextHashReader{ctx: ctx, r: reader}, make([]byte, 1))
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("copy after cancellation = %v, want context canceled", err)
	}
	if reader.reads != 1 {
		t.Fatalf("reader continued after cancellation: %d underlying reads", reader.reads)
	}
}

func TestFileVersionUsesObjectAndChangeIdentityButNotAccessTime(t *testing.T) {
	base := hashVersionInfo{
		size:    128,
		modTime: time.Unix(100, 200),
		mode:    0600,
		sys: hashTestStat{
			Dev:           7,
			Ino:           11,
			Atim:          hashTestTimespec{Sec: 12, Nsec: 13},
			Mtim:          hashTestTimespec{Sec: 100, Nsec: 200},
			Ctim:          hashTestTimespec{Sec: 101, Nsec: 201},
			Birthtimespec: hashTestTimespec{Sec: 80, Nsec: 90},
			Gen:           3,
		},
	}
	original, ok := fileVersion(base)
	if !ok {
		t.Fatal("expected a supported filesystem identity")
	}
	changedAtime := base
	changedAtime.sys = hashTestStat{
		Dev: 7, Ino: 11, Atim: hashTestTimespec{Sec: 999, Nsec: 999},
		Mtim: hashTestTimespec{Sec: 100, Nsec: 200}, Ctim: hashTestTimespec{Sec: 101, Nsec: 201},
		Birthtimespec: hashTestTimespec{Sec: 80, Nsec: 90}, Gen: 3,
	}
	if got, _ := fileVersion(changedAtime); got != original {
		t.Fatalf("access time changed version: %s != %s", got, original)
	}
	for label, mutate := range map[string]func(*hashTestStat){
		"device":     func(stat *hashTestStat) { stat.Dev++ },
		"inode":      func(stat *hashTestStat) { stat.Ino++ },
		"ctime":      func(stat *hashTestStat) { stat.Ctim.Nsec++ },
		"birth time": func(stat *hashTestStat) { stat.Birthtimespec.Nsec++ },
		"generation": func(stat *hashTestStat) { stat.Gen++ },
	} {
		t.Run(label, func(t *testing.T) {
			copy := base
			stat := base.sys.(hashTestStat)
			mutate(&stat)
			copy.sys = stat
			if got, _ := fileVersion(copy); got == original {
				t.Fatalf("%s change did not invalidate version %s", label, got)
			}
		})
	}
}

func TestFileVersionDetectsRewriteAfterModificationTimeRestore(t *testing.T) {
	path := filepath.Join(t.TempDir(), "same-size.bin")
	if err := os.WriteFile(path, []byte("first-value"), 0600); err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	before, err := file.Stat()
	file.Close()
	if err != nil {
		t.Fatal(err)
	}
	first, ok := fileVersion(before)
	if !ok {
		t.Fatal("filesystem does not expose stable device, inode, and change time")
	}
	if err := os.WriteFile(path, []byte("other-value"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, before.ModTime(), before.ModTime()); err != nil {
		t.Fatal(err)
	}
	file, err = os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	after, err := file.Stat()
	file.Close()
	if err != nil {
		t.Fatal(err)
	}
	if before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) {
		t.Fatalf("fixture did not restore size and mtime: before=%d/%s after=%d/%s",
			before.Size(), before.ModTime(), after.Size(), after.ModTime())
	}
	second, ok := fileVersion(after)
	if !ok || second == first {
		t.Fatalf("same-size rewrite with restored mtime retained generation: first=%s second=%s", first, second)
	}
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
