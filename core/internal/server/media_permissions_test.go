package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
)

func TestMediaMemberScopedBeforePaginationAndPerAssetRequest(t *testing.T) {
	dataDir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "valid-owner-password"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "valid-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(admin, "child", "valid-child-password", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	child, err := accounts.Login("child", "valid-child-password")
	if err != nil {
		t.Fatal(err)
	}
	shared, err := files.NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer shared.Close()
	for _, dir := range []string{"family", "private"} {
		if err := shared.Mkdir(dir); err != nil {
			t.Fatal(err)
		}
		for _, ext := range []string{"mp4", "jpg"} {
			if _, err := shared.Upload(dir+"/sample."+ext, bytes.NewBufferString("media-fixture-"+dir)); err != nil {
				t.Fatal(err)
			}
		}
	}
	photos, err := gallery.Open(dataDir, shared)
	if err != nil {
		t.Fatal(err)
	}
	defer photos.Close()
	films, err := cinema.Open(dataDir, shared)
	if err != nil {
		t.Fatal(err)
	}
	defer films.Close()
	if err := photos.StartScan(); err != nil {
		t.Fatal(err)
	}
	if err := films.StartScan(); err != nil {
		t.Fatal(err)
	}
	until := time.Now().Add(10 * time.Second)
	for time.Now().Before(until) {
		if !photos.Status().Running && !films.Status().Running {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if photos.Status().Running || films.Status().Running || photos.Status().LastError != "" || films.Status().LastError != "" {
		t.Fatalf("failed initial media indexing: gallery=%+v cinema=%+v", photos.Status(), films.Status())
	}
	allFilms, _, err := films.List(1, "", "", 20, 0)
	if err != nil || len(allFilms) != 2 {
		t.Fatalf("media indexes invalid: %+v %v", allFilms, err)
	}
	privateID := int64(0)
	for _, item := range allFilms {
		if strings.HasPrefix(item.Path, "private/") {
			privateID = item.ID
		}
	}
	allPhotos, _, err := photos.List(0, 20, 0, false)
	// The gallery intentionally indexes images AND video clips. Two
	// directories with one photo and one film each make four assets.
	if err != nil || len(allPhotos) != 4 {
		t.Fatalf("gallery indexing invalid: %+v %v", allPhotos, err)
	}
	privatePhotoID := int64(0)
	for _, item := range allPhotos {
		if item.Path == "private/sample.jpg" {
			privatePhotoID = item.ID
		}
	}
	if privateID == 0 || privatePhotoID == 0 {
		t.Fatal("private asset ids missing")
	}
	privateAlbum, err := photos.CreateAlbum("private-vacation-album")
	if err != nil {
		t.Fatal(err)
	}
	if err := photos.AddToAlbum(privateAlbum.ID, privatePhotoID); err != nil {
		t.Fatal(err)
	}
	handler := NewWithCinema("", accounts, shared, photos, films)
	call := func(method, route, body, session string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, route, bytes.NewBufferString(body))
		r.Header.Set("X-LightIsle-Request", "1")
		r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	if got := call("GET", "/api/v1/photos", "", child); got.Code != 403 {
		t.Fatalf("ungranted member has photos access %d", got.Code)
	}
	if got := call("GET", "/api/v1/cinema", "", child); got.Code != 403 {
		t.Fatalf("ungranted member has cinema access %d", got.Code)
	}
	grant := "/api/v1/users/" + strconv.FormatInt(member.ID, 10) + "/file-grants"
	if got := call("PUT", grant, `{"path":"family","canWrite":false}`, admin); got.Code != 200 {
		t.Fatalf("cannot grant media folder: %d %s", got.Code, got.Body.String())
	}
	for _, route := range []string{"/api/v1/photos?limit=1", "/api/v1/cinema?limit=1"} {
		got := call("GET", route, "", child)
		if got.Code != 200 || !bytes.Contains(got.Body.Bytes(), []byte("family/")) || bytes.Contains(got.Body.Bytes(), []byte("private/")) {
			t.Fatalf("media page leaks private metadata: %s status=%d %s", route, got.Code, got.Body.String())
		}
	}
	for _, route := range []string{
		"/api/v1/cinema/" + strconv.FormatInt(privateID, 10),
		"/api/v1/cinema/" + strconv.FormatInt(privateID, 10) + "/stream",
		"/api/v1/cinema/" + strconv.FormatInt(privateID, 10) + "/subtitles",
		"/api/v1/cinema/" + strconv.FormatInt(privateID, 10) + "/progress",
		"/api/v1/photos/" + strconv.FormatInt(privatePhotoID, 10) + "/thumbnail",
	} {
		got := call("GET", route, "", child)
		if got.Code != 403 {
			t.Errorf("direct private media ID access succeeded: %s status=%d", route, got.Code)
		}
	}
	if got := call("PUT", "/api/v1/cinema/"+strconv.FormatInt(privateID, 10)+"/progress",
		`{"position":15,"duration":120,"completed":false}`, child); got.Code != 403 {
		t.Fatalf("private media progress modified: status=%d", got.Code)
	}
	if got := call("GET", "/api/v1/photos/albums", "", child); got.Code != 200 || bytes.Contains(got.Body.Bytes(), []byte("private-vacation-album")) {
		t.Fatalf("global private album leaked through metadata: status=%d %s", got.Code, got.Body.String())
	}
	got := call("GET", "/api/v1/photos/status", "", child)
	var result struct {
		Count  int            `json:"count"`
		Status map[string]any `json:"status"`
	}
	if got.Code != 200 || json.Unmarshal(got.Body.Bytes(), &result) != nil || result.Count != 2 {
		t.Fatalf("private gallery count exposed: %d %s", got.Code, got.Body.String())
	}
	if _, ok := result.Status["scanned"]; ok {
		t.Fatal("global scan counters leaked to member")
	}
	got = call("GET", "/api/v1/cinema/status", "", child)
	if got.Code != 200 || bytes.Contains(got.Body.Bytes(), []byte("visited")) {
		t.Fatalf("global cinema counters leaked: %s", got.Body.String())
	}
	got = call("POST", "/api/v1/photos/albums", `{"name":"private-global-album"}`, child)
	if got.Code != 403 {
		t.Fatalf("member can create global album: %d", got.Code)
	}
	if got = call("POST", "/api/v1/photos/"+strconv.FormatInt(privatePhotoID, 10)+"/favorite", `{"favorite":true}`, child); got.Code != 403 {
		t.Fatalf("member modified private photo: %d", got.Code)
	}
	if got = call("DELETE", grant+"?path=family", "", admin); got.Code != 200 {
		t.Fatal("revoke media grant failed")
	}
	if got = call("GET", "/api/v1/cinema", "", child); got.Code != 403 {
		t.Fatalf("revoked member still can browse cinema: %d", got.Code)
	}
}
