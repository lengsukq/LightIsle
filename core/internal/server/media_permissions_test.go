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
	familyPhotoID := int64(0)
	for _, item := range allPhotos {
		if item.Path == "private/sample.jpg" {
			privatePhotoID = item.ID
		}
		if item.Path == "family/sample.jpg" {
			familyPhotoID = item.ID
		}
	}
	if privateID == 0 || privatePhotoID == 0 || familyPhotoID == 0 {
		t.Fatal("private asset ids missing")
	}
	sharedPrivateAlbum, err := photos.CreateAlbum("private-vacation-album")
	if err != nil {
		t.Fatal(err)
	}
	if err := photos.AddToAlbum(sharedPrivateAlbum.ID, privatePhotoID); err != nil {
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
	if got := call("GET", "/api/v2/photos", "", child); got.Code != 403 {
		t.Fatalf("ungranted member has photos access %d", got.Code)
	}
	if got := call("GET", "/api/v2/cinema", "", child); got.Code != 403 {
		t.Fatalf("ungranted member has cinema access %d", got.Code)
	}
	grant := "/api/v2/users/" + strconv.FormatInt(member.ID, 10) + "/file-grants"
	if got := call("PUT", grant, `{"path":"family","canWrite":false}`, admin); got.Code != 200 {
		t.Fatalf("cannot grant media folder: %d %s", got.Code, got.Body.String())
	}
	for _, route := range []string{"/api/v2/photos?limit=1", "/api/v2/cinema?limit=1"} {
		got := call("GET", route, "", child)
		if got.Code != 200 || !bytes.Contains(got.Body.Bytes(), []byte("family/")) || bytes.Contains(got.Body.Bytes(), []byte("private/")) {
			t.Fatalf("media page leaks private metadata: %s status=%d %s", route, got.Code, got.Body.String())
		}
	}
	for _, route := range []string{
		"/api/v2/cinema/" + strconv.FormatInt(privateID, 10),
		"/api/v2/cinema/" + strconv.FormatInt(privateID, 10) + "/stream",
		"/api/v2/cinema/" + strconv.FormatInt(privateID, 10) + "/poster",
		"/api/v2/cinema/" + strconv.FormatInt(privateID, 10) + "/subtitles",
		"/api/v2/cinema/" + strconv.FormatInt(privateID, 10) + "/progress",
		"/api/v2/photos/" + strconv.FormatInt(privatePhotoID, 10) + "/thumbnail",
	} {
		got := call("GET", route, "", child)
		if got.Code != 403 {
			t.Errorf("direct private media ID access succeeded: %s status=%d", route, got.Code)
		}
	}
	if got := call("PUT", "/api/v2/cinema/"+strconv.FormatInt(privateID, 10)+"/progress",
		`{"position":15,"duration":120,"completed":false}`, child); got.Code != 403 {
		t.Fatalf("private media progress modified: status=%d", got.Code)
	}
	if got := call("GET", "/api/v2/photos/albums", "", child); got.Code != 200 || bytes.Contains(got.Body.Bytes(), []byte("private-vacation-album")) {
		t.Fatalf("global private album leaked through metadata: status=%d %s", got.Code, got.Body.String())
	}
	got := call("GET", "/api/v2/photos/status", "", child)
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
	got = call("GET", "/api/v2/cinema/status", "", child)
	if got.Code != 200 || bytes.Contains(got.Body.Bytes(), []byte("visited")) {
		t.Fatalf("global cinema counters leaked: %s", got.Body.String())
	}
	got = call("POST", "/api/v2/photos/albums", `{"name":"private-global-album"}`, child)
	if got.Code != 403 {
		t.Fatalf("member can create global album: %d", got.Code)
	}
	if got = call("POST", "/api/v2/photos/"+strconv.FormatInt(privatePhotoID, 10)+"/favorite", `{"favorite":true}`, child); got.Code != 403 {
		t.Fatalf("member modified private photo: %d", got.Code)
	}
	if got = call("POST", "/api/v2/photos/"+strconv.FormatInt(privatePhotoID, 10)+"/personal-favorite",
		`{"favorite":true}`, child); got.Code != 403 {
		t.Fatalf("member privately favorited another member's media: %d", got.Code)
	}
	if got = call("POST", "/api/v2/photos/"+strconv.FormatInt(familyPhotoID, 10)+"/personal-favorite",
		`{"favorite":true}`, child); got.Code != 200 {
		t.Fatalf("read-only member could not privately favorite authorized media: %d %s", got.Code, got.Body.String())
	}
	if got = call("GET", "/api/v2/photos?personal=1", "", child); got.Code != 200 ||
		!bytes.Contains(got.Body.Bytes(), []byte("family/sample.jpg")) ||
		bytes.Contains(got.Body.Bytes(), []byte("private/sample.jpg")) {
		t.Fatalf("member private favorites leaked other media: %d %s", got.Code, got.Body.String())
	}
	if got = call("GET", "/api/v2/photos?personal=1", "", admin); got.Code != 200 ||
		bytes.Contains(got.Body.Bytes(), []byte("family/sample.jpg")) {
		t.Fatalf("private favorites leaked to admin or another user: %d %s", got.Code, got.Body.String())
	}
	created := call("POST", "/api/v2/photos/private-albums", `{"name":"孩子的私人照片"}`, child)
	if created.Code != 201 {
		t.Fatalf("read-only member cannot create own album: %d %s", created.Code, created.Body.String())
	}
	var privateAlbum struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(created.Body.Bytes(), &privateAlbum); err != nil || privateAlbum.ID <= 0 {
		t.Fatalf("invalid album response: %v %s", err, created.Body.String())
	}
	albumPath := "/api/v2/photos/private-albums/" + strconv.FormatInt(privateAlbum.ID, 10)
	if got = call("POST", albumPath+"/items", `{"assetId":`+strconv.FormatInt(privatePhotoID, 10)+`}`, child); got.Code != 403 {
		t.Fatalf("read-only member inserted photo outside grant: %d", got.Code)
	}
	if got = call("POST", albumPath+"/items", `{"assetId":`+strconv.FormatInt(familyPhotoID, 10)+`}`, child); got.Code != 200 {
		t.Fatalf("read-only member couldn't add authorized photo: %d %s", got.Code, got.Body.String())
	}
	if got = call("GET", "/api/v2/photos?privateAlbum="+strconv.FormatInt(privateAlbum.ID, 10), "", child); got.Code != 200 ||
		!bytes.Contains(got.Body.Bytes(), []byte("family/sample.jpg")) || bytes.Contains(got.Body.Bytes(), []byte("private/sample.jpg")) {
		t.Fatalf("private album did not respect scoped pagination: %d %s", got.Code, got.Body.String())
	}
	if got = call("GET", "/api/v2/photos/private-albums", "", admin); got.Code != 200 ||
		bytes.Contains(got.Body.Bytes(), []byte("孩子的私人照片")) {
		t.Fatalf("admin saw member private album: %d %s", got.Code, got.Body.String())
	}
	if got = call("GET", "/api/v2/photos?privateAlbum="+strconv.FormatInt(privateAlbum.ID, 10), "", admin); got.Code != 404 {
		t.Fatalf("other user used child's private album ID: %d", got.Code)
	}
	if got = call("PATCH", albumPath, `{"name":"admin renamed child"}`, admin); got.Code != 404 {
		t.Fatalf("admin renamed other's private album: %d", got.Code)
	}
	if got = call("DELETE", albumPath, "", admin); got.Code != 404 {
		t.Fatalf("admin deleted other's private album: %d", got.Code)
	}
	if got = call("PATCH", albumPath, `{"name":"孩子自己的相册"}`, child); got.Code != 200 {
		t.Fatalf("private album rename failed: %d %s", got.Code, got.Body.String())
	}
	if got = call("GET", "/api/v2/audit?limit=30", "", child); got.Code != 403 {
		t.Fatalf("nonadmin could read audit history: %d", got.Code)
	}
	if got = call("GET", "/api/v2/audit?limit=30", "", admin); got.Code != 200 ||
		!bytes.Contains(got.Body.Bytes(), []byte("gallery_write")) ||
		bytes.Contains(got.Body.Bytes(), []byte("strong-child-password")) {
		t.Fatalf("audit history missing write events or leaked credentials: %d %s", got.Code, got.Body.String())
	}
	if got = call("DELETE", albumPath+"/items/"+strconv.FormatInt(familyPhotoID, 10), "", child); got.Code != 200 {
		t.Fatalf("private album member removal failed: %d", got.Code)
	}
	if got = call("DELETE", grant+"?path=family", "", admin); got.Code != 200 {
		t.Fatal("revoke media grant failed")
	}
	if got = call("GET", "/api/v2/cinema", "", child); got.Code != 403 {
		t.Fatalf("revoked member still can browse cinema: %d", got.Code)
	}
}
