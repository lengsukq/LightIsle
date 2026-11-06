package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

type rootRoutingProvider struct{}

func (rootRoutingProvider) Capture(_ context.Context, name string) (storageidentity.Binding, error) {
	resolved, err := filepath.EvalSymlinks(name)
	if err != nil {
		return storageidentity.Binding{}, err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return storageidentity.Binding{}, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return storageidentity.Binding{}, errors.New("directory identity unavailable")
	}
	return storageidentity.Binding{
		Path: filepath.Clean(resolved), VolumeUUID: "12345678-1234-1234-1234-123456789abc",
		DirectoryID: stat.Ino, BirthSec: stat.Birthtimespec.Sec, BirthNsec: stat.Birthtimespec.Nsec, Generation: uint64(stat.Gen),
	}, nil
}

func TestCinemaFilmDeletionHintFollowsMemberWriteGrant(t *testing.T) {
	f := newRootRoutingFixture(t)
	filename := filepath.Join(f.pathA, "visible", "FamilyMovie.mkv")
	if err := os.MkdirAll(filepath.Dir(filename), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filename, []byte("safe family film test input"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootA.ID, "visible", false); err != nil {
		t.Fatal(err)
	}
	startRootScans(t, f, f.rootA.ID)
	list := func() (int64, bool) {
		r := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/cinema?limit=120"), "")
		if r.Code != http.StatusOK {
			t.Fatalf("member cinema read: %d %s", r.Code, r.Body.String())
		}
		var body struct {
			Films []struct {
				ID       int64 `json:"id"`
				CanWrite bool  `json:"canWrite"`
			} `json:"films"`
		}
		if err := json.Unmarshal(r.Body.Bytes(), &body); err != nil || len(body.Films) != 1 {
			t.Fatalf("movie list: %+v %v", body, err)
		}
		return body.Films[0].ID, body.Films[0].CanWrite
	}
	id, canWrite := list()
	if canWrite {
		t.Fatal("read-only member is offered a destructive cinema action")
	}
	denied := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/files/batch"),
		`{"action":"trash","paths":["visible/FamilyMovie.mkv"]}`)
	if denied.Code != http.StatusOK || !strings.Contains(denied.Body.String(), `"success":false`) {
		t.Fatalf("read-only member deleted a film: %d %s", denied.Code, denied.Body.String())
	}
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootA.ID, "visible", true); err != nil {
		t.Fatal(err)
	}
	if newID, yes := list(); newID != id || !yes {
		t.Fatalf("grant change not reflected in viewer cinema data: id=%d expected=%d write=%v", newID, id, yes)
	}
	detail := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/cinema/"+strconv.FormatInt(id, 10)), "")
	if detail.Code != http.StatusOK || !strings.Contains(detail.Body.String(), `"canWrite":true`) {
		t.Fatalf("cinema detail omitted viewer write authority: %d %s", detail.Code, detail.Body.String())
	}
	allowed := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/files/batch"),
		`{"action":"trash","paths":["visible/FamilyMovie.mkv"]}`)
	if allowed.Code != http.StatusOK || !strings.Contains(allowed.Body.String(), `"success":true`) {
		t.Fatalf("authorized member could not trash their film: %d %s", allowed.Code, allowed.Body.String())
	}
	if _, err := os.Stat(filename); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("trashed media remained at original path: %v", err)
	}
}

func (p rootRoutingProvider) Verify(ctx context.Context, binding storageidentity.Binding) error {
	current, err := p.Capture(ctx, binding.Path)
	if err != nil {
		return err
	}
	if !storageidentity.Equal(current, binding) {
		return storageidentity.ErrMismatch
	}
	return nil
}

func TestRootRoutesPinSameRelativePathToDifferentRoots(t *testing.T) {
	base := t.TempDir()
	volume := filepath.Join(base, "volume")
	if err := os.Mkdir(volume, 0700); err != nil {
		t.Fatal(err)
	}
	rootAPath := filepath.Join(volume, "photos-a")
	rootBPath := filepath.Join(volume, "photos-b")
	for _, path := range []string{rootAPath, rootBPath} {
		if err := os.Mkdir(path, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(rootAPath, "same.txt"), []byte("from-root-a"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(rootBPath, "same.txt"), []byte("from-root-b"), 0600); err != nil {
		t.Fatal(err)
	}

	dataDir := filepath.Join(base, "app-data")
	if err := os.Mkdir(dataDir, 0700); err != nil {
		t.Fatal(err)
	}
	registry, err := roots.OpenWithProvider(dataDir, rootRoutingProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	rootA, err := registry.Add(context.Background(), "Photos A", rootAPath)
	if err != nil {
		t.Fatal(err)
	}
	rootB, err := registry.Add(context.Background(), "Photos B", rootBPath)
	if err != nil {
		t.Fatal(err)
	}

	accounts, err := auth.Open(filepath.Join(base, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "long-initial-password"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "long-initial-password")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(admin, "member", "member-password-12345", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	if err := accounts.SetRootGrant(admin, member.ID, rootA.ID, ".", false); err != nil {
		t.Fatal(err)
	}
	memberToken, err := accounts.Login("member", "member-password-12345")
	if err != nil {
		t.Fatal(err)
	}

	factory := func(ctx context.Context, root roots.Root, lease *roots.Lease) (*RootServices, error) {
		manager, err := files.NewPinnedManager(lease.Root)
		if err != nil {
			return nil, err
		}
		photos, err := gallery.OpenRootScoped(dataDir, manager, root.ID, gallery.Options{RootGeneration: root.Generation})
		if err != nil {
			_ = manager.Close()
			return nil, err
		}
		films, err := cinema.OpenRootScoped(dataDir, manager, root.ID, root.Generation)
		if err != nil {
			_ = photos.Close()
			_ = manager.Close()
			return nil, err
		}
		journal, err := tasks.OpenRootScoped(dataDir, root.ID)
		if err != nil {
			_ = films.Close()
			_ = photos.Close()
			_ = manager.Close()
			return nil, err
		}
		photos.SetJournal(journal)
		films.SetJournal(journal)
		return &RootServices{Files: manager, Gallery: photos, Cinema: films, Journal: journal}, nil
	}
	server := NewWithRoots("", accounts, nil, nil, nil, nil, registry, factory)
	defer func() {
		if err := server.Shutdown(); err != nil {
			t.Errorf("shutdown root server: %v", err)
		}
	}()

	call := func(rootID, session string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/api/v2/roots/"+rootID+"/files/content?path=same.txt", nil)
		req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		res := httptest.NewRecorder()
		server.ServeHTTP(res, req)
		return res
	}
	for _, item := range []struct {
		rootID string
		body   string
	}{{rootA.ID, "from-root-a"}, {rootB.ID, "from-root-b"}} {
		response := call(item.rootID, admin)
		if response.Code != http.StatusOK || response.Body.String() != item.body {
			t.Fatalf("root %s read = %d %q, want %q", item.rootID, response.Code, response.Body.String(), item.body)
		}
	}
	if response := call(rootA.ID, memberToken); response.Code != http.StatusOK || response.Body.String() != "from-root-a" {
		t.Fatalf("member read granted root = %d %q", response.Code, response.Body.String())
	}
	if response := call(rootB.ID, memberToken); response.Code != http.StatusNotFound {
		t.Fatalf("member crossed root grant boundary = %d %q", response.Code, response.Body.String())
	}
	// Global compatibility URLs no longer consult a separate mutable legacy
	// share. They resolve RootRegistry's verified default identity instead.
	defaultRead := func() *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/api/v2/files/content?path=same.txt", nil)
		req.AddCookie(&http.Cookie{Name: sessionCookie, Value: admin})
		res := httptest.NewRecorder()
		server.ServeHTTP(res, req)
		return res
	}
	if res := defaultRead(); res.Code != http.StatusOK || res.Body.String() != "from-root-a" {
		t.Fatalf("initial default root read: %d %q", res.Code, res.Body.String())
	}
	if err := registry.SetDefault(context.Background(), rootB.ID, rootB.Generation); err != nil {
		t.Fatal(err)
	}
	if res := defaultRead(); res.Code != http.StatusOK || res.Body.String() != "from-root-b" {
		t.Fatalf("switched default root read: %d %q", res.Code, res.Body.String())
	}
	for _, retired := range []struct{ method, path string }{
		{http.MethodGet, "/api/v2/users/1/file-grants"},
		{http.MethodPut, "/api/v2/users/1/file-grants"},
		{http.MethodGet, "/api/v2/public/file/old-single-root-capability"},
	} {
		request := httptest.NewRequest(retired.method, retired.path, nil)
		request.AddCookie(&http.Cookie{Name: sessionCookie, Value: admin})
		if retired.method != http.MethodGet {
			request.Header.Set("X-LightIsle-Request", "1")
		}
		response := httptest.NewRecorder()
		server.ServeHTTP(response, request)
		if response.Code != http.StatusGone {
			t.Fatalf("retired single-root API %s %s was not closed: %d", retired.method, retired.path, response.Code)
		}
	}
	// DAV credentials are independent of web sessions. They must follow
	// RootRegistry's selected identity and enforce root-specific grants,
	// regardless of historical legacy permissions on the same path.
	adminCredential, adminDAVPassword, err := accounts.CreateDAVCredential(admin, "admin-root-dav")
	if err != nil {
		t.Fatal(err)
	}
	_ = adminCredential
	_, memberDAVPassword, err := accounts.CreateDAVCredential(memberToken, "member-root-dav")
	if err != nil {
		t.Fatal(err)
	}
	davRead := func(user, password string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/dav/same.txt", nil)
		req.SetBasicAuth(user, password)
		res := httptest.NewRecorder()
		server.ServeHTTP(res, req)
		return res
	}
	if res := davRead("owner", adminDAVPassword); res.Code != http.StatusOK || res.Body.String() != "from-root-b" {
		t.Fatalf("root-bound DAV read did not follow default root: %d %q", res.Code, res.Body.String())
	}
	if res := davRead("member", memberDAVPassword); res.Code == http.StatusOK {
		t.Fatalf("member DAV bypassed root B authorization: %d %q", res.Code, res.Body.String())
	}
	if err := registry.SetDefault(context.Background(), rootA.ID, rootA.Generation); err != nil {
		t.Fatal(err)
	}
	if res := davRead("member", memberDAVPassword); res.Code != http.StatusOK || res.Body.String() != "from-root-a" {
		t.Fatalf("member DAV failed authorized root A read: %d %q", res.Code, res.Body.String())
	}
	if err := registry.SetDefault(context.Background(), rootB.ID, rootB.Generation); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/dav/", "/api/v2/downloads"} {
		res := httptest.NewRecorder()
		server.ServeHTTP(res, httptest.NewRequest(http.MethodGet, path, nil))
		if res.Code != http.StatusUnauthorized {
			t.Fatalf("unauthenticated root channel %s did not require credentials: %d", path, res.Code)
		}
	}
	discovery := httptest.NewRecorder()
	server.ServeHTTP(discovery, httptest.NewRequest(http.MethodGet, "/api/v2/roots", nil))
	if discovery.Code != http.StatusNotFound {
		t.Fatal("root discovery was exposed before explicit enablement")
	}

	for _, name := range []string{"gallery-root-" + rootA.ID + ".sqlite", "cinema-root-" + rootA.ID + ".sqlite", "tasks-root-" + rootA.ID + ".sqlite"} {
		if _, err := os.Stat(filepath.Join(dataDir, name)); err != nil {
			t.Errorf("missing flat root database %s: %v", name, err)
		}
	}
}

func TestRootShareCannotBeDownloadedThroughAnotherRoot(t *testing.T) {
	base := t.TempDir()
	volume := filepath.Join(base, "volume")
	if err := os.Mkdir(volume, 0700); err != nil {
		t.Fatal(err)
	}
	paths := []string{filepath.Join(volume, "one"), filepath.Join(volume, "two"), filepath.Join(volume, "replacement")}
	for _, path := range paths {
		if err := os.Mkdir(path, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(path, "same.txt"), []byte(path), 0600); err != nil {
			t.Fatal(err)
		}
	}
	dataDir := filepath.Join(base, "app-data")
	if err := os.Mkdir(dataDir, 0700); err != nil {
		t.Fatal(err)
	}
	registry, err := roots.OpenWithProvider(dataDir, rootRoutingProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	rootA, err := registry.Add(context.Background(), "One", paths[0])
	if err != nil {
		t.Fatal(err)
	}
	rootB, err := registry.Add(context.Background(), "Two", paths[1])
	if err != nil {
		t.Fatal(err)
	}
	accounts, err := auth.Open(filepath.Join(base, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "long-initial-password"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "long-initial-password")
	if err != nil {
		t.Fatal(err)
	}
	factory := func(_ context.Context, _ roots.Root, lease *roots.Lease) (*RootServices, error) {
		manager, err := files.NewPinnedManager(lease.Root)
		if err != nil {
			return nil, err
		}
		return &RootServices{Files: manager}, nil
	}
	server := NewWithRoots("", accounts, nil, nil, nil, nil, registry, factory)
	defer server.Shutdown()

	req := httptest.NewRequest(http.MethodPost, "/api/v2/roots/"+rootA.ID+"/file-shares", bytes.NewBufferString(`{"path":"same.txt","hours":1}`))
	req.AddCookie(&http.Cookie{Name: sessionCookie, Value: admin})
	req.Header.Set("X-LightIsle-Request", "1")
	req.Header.Set(rootGenerationHeader, strconv.FormatUint(rootA.Generation, 10))
	response := httptest.NewRecorder()
	server.ServeHTTP(response, req)
	if response.Code != http.StatusCreated {
		t.Fatalf("create root share = %d %s", response.Code, response.Body.String())
	}
	var payload struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil || payload.Token == "" {
		t.Fatalf("share response = %s (%v)", response.Body.String(), err)
	}
	for _, test := range []struct {
		rootID string
		status int
	}{{rootA.ID, http.StatusOK}, {rootB.ID, http.StatusNotFound}} {
		request := httptest.NewRequest(http.MethodGet, "/api/v2/roots/"+test.rootID+"/public/file/"+payload.Token, nil)
		out := httptest.NewRecorder()
		server.ServeHTTP(out, request)
		if out.Code != test.status {
			t.Errorf("share via root %s = %d %s, want %d", test.rootID, out.Code, out.Body.String(), test.status)
		}
	}
	if _, err := registry.Rebind(context.Background(), rootA.ID, paths[2]); !errors.Is(err, roots.ErrDifferentDirectory) {
		t.Fatalf("unrelated folder unexpectedly inherited original root grant: %v", err)
	}
	// An explicit rebind of the ORIGINAL physical directory still increments
	// generation, invalidating old share URLs without changing member ACL.
	if _, err := registry.Rebind(context.Background(), rootA.ID, paths[0]); err != nil {
		t.Fatalf("rebind verified original folder: %v", err)
	}
	request := httptest.NewRequest(http.MethodGet, "/api/v2/roots/"+rootA.ID+"/public/file/"+payload.Token, nil)
	afterRebind := httptest.NewRecorder()
	server.ServeHTTP(afterRebind, request)
	if afterRebind.Code != http.StatusNotFound {
		t.Fatalf("old generation share survived rebind = %d %s", afterRebind.Code, afterRebind.Body.String())
	}
}

type rootRoutingFixture struct {
	base     string
	dataDir  string
	volume   string
	pathA    string
	pathB    string
	rootA    roots.Root
	rootB    roots.Root
	registry *roots.Registry
	accounts *auth.Store
	server   *RootServer
	admin    string
	member   string
	memberID int64
	services map[string]*RootServices
}

func newRootRoutingFixture(t *testing.T, options ...RootServerOptions) *rootRoutingFixture {
	t.Helper()
	base := t.TempDir()
	volume := filepath.Join(base, "volume")
	pathA := filepath.Join(volume, "root-a")
	pathB := filepath.Join(volume, "root-b")
	for _, path := range []string{pathA, pathB} {
		if err := os.MkdirAll(path, 0700); err != nil {
			t.Fatal(err)
		}
	}
	dataDir := filepath.Join(base, "app-data")
	if err := os.Mkdir(dataDir, 0700); err != nil {
		t.Fatal(err)
	}
	registry, err := roots.OpenWithProvider(dataDir, rootRoutingProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	rootA, err := registry.Add(context.Background(), "Root A", pathA)
	if err != nil {
		t.Fatal(err)
	}
	rootB, err := registry.Add(context.Background(), "Root B", pathB)
	if err != nil {
		t.Fatal(err)
	}
	accounts, err := auth.Open(filepath.Join(base, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if err := accounts.Setup("owner", "long-initial-password"); err != nil {
		_ = accounts.Close()
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "long-initial-password")
	if err != nil {
		_ = accounts.Close()
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(admin, "member", "member-password-12345", auth.RoleMember)
	if err != nil {
		_ = accounts.Close()
		t.Fatal(err)
	}
	memberSession, err := accounts.Login("member", "member-password-12345")
	if err != nil {
		_ = accounts.Close()
		t.Fatal(err)
	}
	services := make(map[string]*RootServices)
	factory := func(_ context.Context, root roots.Root, lease *roots.Lease) (*RootServices, error) {
		manager, err := files.NewPinnedManager(lease.Root)
		if err != nil {
			return nil, err
		}
		photos, err := gallery.OpenRootScoped(dataDir, manager, root.ID, gallery.Options{RootGeneration: root.Generation})
		if err != nil {
			_ = manager.Close()
			return nil, err
		}
		films, err := cinema.OpenRootScoped(dataDir, manager, root.ID, root.Generation)
		if err != nil {
			_ = photos.Close()
			_ = manager.Close()
			return nil, err
		}
		journal, err := tasks.OpenRootScoped(dataDir, root.ID)
		if err != nil {
			_ = films.Close()
			_ = photos.Close()
			_ = manager.Close()
			return nil, err
		}
		photos.SetJournal(journal)
		films.SetJournal(journal)
		result := &RootServices{Files: manager, Gallery: photos, Cinema: films, Journal: journal}
		services[root.ID] = result
		return result, nil
	}
	server := NewWithRoots("", accounts, nil, nil, nil, nil, registry, factory, options...)
	fixture := &rootRoutingFixture{
		base: base, dataDir: dataDir, volume: volume, pathA: pathA, pathB: pathB,
		rootA: rootA, rootB: rootB, registry: registry, accounts: accounts,
		server: server, admin: admin, member: memberSession, memberID: member.ID, services: services,
	}
	t.Cleanup(func() {
		if err := server.Shutdown(); err != nil {
			t.Errorf("shutdown root server: %v", err)
		}
		if err := accounts.Close(); err != nil {
			t.Errorf("close account store: %v", err)
		}
	})
	return fixture
}

func (f *rootRoutingFixture) call(session, method, route, body string) *httptest.ResponseRecorder {
	return f.callWithGeneration(session, method, route, body, true, "")
}

func (f *rootRoutingFixture) callWithGeneration(session, method, route, body string, useCurrent bool, generation string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, route, bytes.NewBufferString(body))
	req.Header.Set("X-LightIsle-Request", "1")
	if generation != "" {
		req.Header.Set(rootGenerationHeader, generation)
	} else if useCurrent && rootRequestMutates(method) {
		if rootID := rootIDFromRoute(route); rootID != "" {
			for _, root := range f.registry.List() {
				if root.ID == rootID {
					req.Header.Set(rootGenerationHeader, strconv.FormatUint(root.Generation, 10))
					break
				}
			}
		}
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if session != "" {
		req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
	}
	response := httptest.NewRecorder()
	f.server.ServeHTTP(response, req)
	return response
}

func rootIDFromRoute(route string) string {
	const prefix = "/api/v2/roots/"
	trimmed := strings.TrimPrefix(route, prefix)
	if trimmed == route {
		return ""
	}
	rootID, _, _ := strings.Cut(trimmed, "/")
	return rootID
}

func rootRoute(id, suffix string) string { return "/api/v2/roots/" + id + suffix }

func TestRootThumbnailUsesThumbnailHandlerNotOriginalFilePreview(t *testing.T) {
	f := newRootRoutingFixture(t)
	if err := os.WriteFile(filepath.Join(f.pathA, "readme.txt"), []byte("this is original source content"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		method string
		url    string
		status int
		code   string
	}{
		{http.MethodGet, "/files/thumbnail?path=readme.txt", http.StatusNotFound, "thumbnail_unsupported"},
		{http.MethodHead, "/files/thumbnail?path=readme.txt", http.StatusNotFound, ""},
		{http.MethodGet, "/files/thumbnail?path=readme.txt&size=1024", http.StatusBadRequest, "invalid_request"},
		{http.MethodGet, "/files/preview?path=readme.txt", http.StatusOK, ""},
	} {
		res := f.call(f.admin, test.method, rootRoute(f.rootA.ID, test.url), "")
		if res.Code != test.status || (test.code != "" && !strings.Contains(res.Body.String(), test.code)) {
			t.Errorf("%s %s: got %d %s; want %d %s", test.method, test.url, res.Code, res.Body.String(), test.status, test.code)
		}
	}
}

func TestRootThumbnailActuallyRendersBoundedJPEG(t *testing.T) {
	f := newRootRoutingFixture(t)
	source, err := os.OpenFile(filepath.Join(f.pathA, "sample.png"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	pixels := image.NewRGBA(image.Rect(0, 0, 600, 300))
	for y := 0; y < 300; y++ {
		for x := 0; x < 600; x++ {
			pixels.Set(x, y, color.RGBA{R: uint8(x % 256), G: uint8(y % 256), B: 130, A: 255})
		}
	}
	if err := png.Encode(source, pixels); err != nil {
		source.Close()
		t.Fatal(err)
	}
	if err := source.Close(); err != nil {
		t.Fatal(err)
	}
	for _, limit := range []int{512, 2048} {
		url := rootRoute(f.rootA.ID, "/files/thumbnail?path=sample.png&size="+strconv.Itoa(limit))
		result := f.call(f.admin, http.MethodGet, url, "")
		if result.Code != http.StatusOK {
			t.Fatalf("thumb size %d: status %d body %s", limit, result.Code, result.Body.String())
		}
		if got := result.Header().Get("Content-Type"); got != "image/jpeg" {
			t.Fatalf("thumbnail type %q, want image/jpeg", got)
		}
		img, err := jpeg.Decode(bytes.NewReader(result.Body.Bytes()))
		if err != nil {
			t.Fatalf("thumbnail %d is not decodable JPEG: %v", limit, err)
		}
		if img.Bounds().Dx() > limit || img.Bounds().Dy() > limit {
			t.Fatalf("thumbnail size %d exceeded max pixel: %v", limit, img.Bounds())
		}
		if result := f.call(f.admin, http.MethodHead, url, ""); result.Code != http.StatusOK {
			t.Fatalf("thumbnail HEAD size %d: %d", limit, result.Code)
		}
	}
}

func TestRootPreviewReadsSharedTrashRetentionWithoutChangingThePolicy(t *testing.T) {
	retention := tasks.OpenRetentionStore(filepath.Join(t.TempDir(), "trash-retention.json"))
	if _, err := retention.Set(tasks.Retention{Enabled: true, Days: 45}); err != nil {
		t.Fatal(err)
	}
	f := newRootRoutingFixture(t, RootServerOptions{TrashRetention: retention})
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootA.ID, ".", false); err != nil {
		t.Fatal(err)
	}
	verify := func(session, route string, status int, enabled bool, days int) {
		t.Helper()
		res := f.call(session, http.MethodGet, route, "")
		if res.Code != status {
			t.Errorf("GET %s: status %d body %s; want %d", route, res.Code, res.Body.String(), status)
			return
		}
		if status != http.StatusOK {
			return
		}
		var got tasks.Retention
		if err := json.Unmarshal(res.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		if got.Enabled != enabled || got.Days != days {
			t.Errorf("GET %s: retention %+v; want enabled=%v days=%d", route, got, enabled, days)
		}
	}
	for _, route := range []string{
		"/api/v2/trash/retention",
		rootRoute(f.rootA.ID, "/trash/retention"),
		rootRoute(f.rootB.ID, "/trash/retention"),
	} {
		verify(f.admin, route, http.StatusOK, false, 45)
	}
	verify(f.member, rootRoute(f.rootA.ID, "/trash/retention"), http.StatusOK, false, 45)
	verify(f.member, rootRoute(f.rootB.ID, "/trash/retention"), http.StatusNotFound, false, 0)
	verify("", "/api/v2/trash/retention", http.StatusUnauthorized, false, 0)
	verify("", rootRoute(f.rootA.ID, "/trash/retention"), http.StatusUnauthorized, false, 0)

	// The effective policy stays disabled without erasing the saved setting.
	if !retention.Get().Enabled {
		t.Fatal("reading the effective policy changed the saved preference")
	}
	if _, err := retention.Set(tasks.Retention{Enabled: false, Days: 45}); err != nil {
		t.Fatal(err)
	}
	verify(f.admin, "/api/v2/trash/retention", http.StatusOK, false, 45)
	verify(f.admin, rootRoute(f.rootA.ID, "/trash/retention"), http.StatusOK, false, 45)
}

func TestRootDiscoveryIncludesSubtreeGrantedRootWithoutLeakingPath(t *testing.T) {
	f := newRootRoutingFixture(t, RootServerOptions{EnableDiscovery: true})
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootA.ID, "visible", false); err != nil {
		t.Fatal(err)
	}
	response := f.call(f.member, http.MethodGet, "/api/v2/roots", "")
	if response.Code != http.StatusOK {
		t.Fatalf("root discovery: %d %s", response.Code, response.Body.String())
	}
	var payload struct {
		Roots []map[string]any `json:"roots"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Roots) != 1 || payload.Roots[0]["rootID"] != f.rootA.ID || payload.Roots[0]["name"] != "Root A" || payload.Roots[0]["online"] != true {
		t.Fatalf("subtree grant did not discover only its root: %+v", payload.Roots)
	}
	if _, exists := payload.Roots[0]["path"]; exists {
		t.Fatalf("root discovery exposed physical path: %+v", payload.Roots[0])
	}
	if _, exists := payload.Roots[0]["volumeMount"]; exists {
		t.Fatalf("member root discovery exposed physical mount: %+v", payload.Roots[0])
	}
	if res := f.call(f.member, http.MethodGet, "/api/v2/system", ""); res.Code != http.StatusForbidden {
		t.Fatalf("member must not read whole-host physical volumes: %d %s", res.Code, res.Body.String())
	}
	if _, exists := payload.Roots[0]["binding"]; exists {
		t.Fatalf("root discovery exposed physical binding: %+v", payload.Roots[0])
	}
	if _, exists := payload.Roots[0]["compatibility"]; exists {
		t.Fatalf("beta-only root discovery should not expose a legacy migration marker: %+v", payload.Roots[0])
	}
	if payload.Roots[0]["capacityScope"] != "underlying_filesystem_shared" {
		t.Fatalf("online root must identify volume-wide, non-dedicated capacity: %+v", payload.Roots[0])
	}
	free, available := payload.Roots[0]["filesystemAvailableBytes"].(float64)
	if !available || free <= 0 {
		t.Fatalf("online root has no filesystem free-space metric: %+v", payload.Roots[0])
	}
	adminResponse := f.call(f.admin, http.MethodGet, "/api/v2/roots", "")
	if adminResponse.Code != http.StatusOK {
		t.Fatalf("admin discovery: %d %s", adminResponse.Code, adminResponse.Body.String())
	}
	var adminPayload struct {
		Roots []map[string]any
	}
	if err := json.Unmarshal(adminResponse.Body.Bytes(), &adminPayload); err != nil {
		t.Fatal(err)
	}
	if len(adminPayload.Roots) != 2 {
		t.Fatalf("admin expected two registered roots: %+v", adminPayload.Roots)
	}
	for _, root := range adminPayload.Roots {
		if mount, ok := root["volumeMount"].(string); !ok || mount == "" {
			t.Fatalf("admin missing volume association: %+v", root)
		}
		if _, exists := root["path"]; exists {
			t.Fatalf("admin should not receive an arbitrary browse path: %+v", root)
		}
	}
}

func TestUnauthorizedRootRequestDoesNotCreateRootServices(t *testing.T) {
	f := newRootRoutingFixture(t)
	response := f.call(f.member, http.MethodGet, rootRoute(f.rootB.ID, "/files?path=."), "")
	if response.Code != http.StatusNotFound || !strings.Contains(response.Body.String(), "root_not_found") {
		t.Fatalf("unauthorized root response = %d %s", response.Code, response.Body.String())
	}
	if f.services[f.rootB.ID] != nil {
		t.Fatal("unauthorized request created root services")
	}
	for _, name := range []string{"gallery-root-" + f.rootB.ID + ".sqlite", "cinema-root-" + f.rootB.ID + ".sqlite", "tasks-root-" + f.rootB.ID + ".sqlite"} {
		if _, err := os.Stat(filepath.Join(f.dataDir, name)); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("unauthorized request initialized %s: %v", name, err)
		}
	}
}
