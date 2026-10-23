package server

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
)

func TestAlbumManagementHTTPPermissionsValidationAndOriginalPreservation(t *testing.T) {
	dir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "album-owner-password"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "album-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(admin, "viewer", "album-viewer-password", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	viewer, err := accounts.Login("viewer", "album-viewer-password")
	if err != nil {
		t.Fatal(err)
	}
	if err := accounts.SetFileGrant(admin, member.ID, ".", false); err != nil {
		t.Fatal(err)
	}
	storage, err := files.NewManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	const original = "album management must not modify the original file"
	if _, err := storage.Upload("photo.jpg", bytes.NewBufferString(original)); err != nil {
		t.Fatal(err)
	}
	photos, err := gallery.Open(dir, storage)
	if err != nil {
		t.Fatal(err)
	}
	defer photos.Close()
	if err := photos.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for photos.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	assets, _, err := photos.List(0, 10, 0, false)
	if err != nil || len(assets) != 1 || photos.Status().Running {
		t.Fatalf("scan fixture failed: %+v %v", assets, err)
	}
	assetID := assets[0].ID
	if err := photos.Favorite(assetID, true); err != nil {
		t.Fatal(err)
	}
	album, err := photos.CreateAlbum("old name")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := photos.CreateAlbum("taken name"); err != nil {
		t.Fatal(err)
	}
	if err := photos.AddToAlbum(album.ID, assetID); err != nil {
		t.Fatal(err)
	}
	handler := New("", accounts, storage, photos)
	call := func(method, route, body, session string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, route, bytes.NewBufferString(body))
		req.Header.Set("X-LightIsle-Request", "1")
		if session != "" {
			req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, req)
		return response
	}
	route := "/api/v1/photos/albums/" + strconv.FormatInt(album.ID, 10)
	itemRoute := route + "/items/" + strconv.FormatInt(assetID, 10)
	for _, endpoint := range []string{"/api/v1/files?path=.", "/api/v1/files/search?query=photo", "/api/v1/photos"} {
		for _, session := range []string{viewer, admin} {
			got := call("GET", endpoint, "", session)
			var page struct {
				CanWrite bool `json:"canWrite"`
				Entries  []struct {
					CanWrite bool `json:"canWrite"`
				} `json:"entries"`
				Assets []struct {
					CanWrite bool `json:"canWrite"`
				} `json:"assets"`
			}
			if got.Code != 200 || json.Unmarshal(got.Body.Bytes(), &page) != nil {
				t.Fatalf("permission hint response %s: %d %s", endpoint, got.Code, got.Body.String())
			}
			wantWrite := session == admin
			if len(page.Entries) == 0 && len(page.Assets) == 0 {
				t.Fatalf("missing fixture in %s: %s", endpoint, got.Body.String())
			}
			for _, entry := range page.Entries {
				if entry.CanWrite != wantWrite {
					t.Fatalf("wrong entry hint %s: %s", endpoint, got.Body.String())
				}
			}
			for _, asset := range page.Assets {
				if asset.CanWrite != wantWrite {
					t.Fatalf("wrong shared-favorite hint: %s", got.Body.String())
				}
			}
			if len(page.Entries) > 0 && page.CanWrite != wantWrite {
				t.Fatalf("wrong directory hint: %s", got.Body.String())
			}
		}
	}
	for _, operation := range []struct{ method, path, body string }{
		{"PATCH", route, `{"name":"unauthorized"}`},
		{"DELETE", route, ""},
		{"DELETE", itemRoute, ""},
	} {
		for _, identity := range []struct {
			session string
			status  int
		}{{"", 401}, {viewer, 403}} {
			if got := call(operation.method, operation.path, operation.body, identity.session); got.Code != identity.status {
				t.Fatalf("album mutation permission %s: %d %s", operation.path, got.Code, got.Body.String())
			}
		}
	}
	for _, body := range []string{`{}`, `{"name":""}`, `{"name":"bad\nname"}`, `{"name":"ok","extra":true}`, `{"name":"ok"}{}`, "invalid"} {
		if got := call("PATCH", route, body, admin); got.Code != 400 {
			t.Errorf("invalid rename body %q: %d %s", body, got.Code, got.Body.String())
		}
	}
	if got := call("PATCH", route, `{"name":"taken name"}`, admin); got.Code != 409 {
		t.Fatalf("duplicate rename: %d %s", got.Code, got.Body.String())
	}
	got := call("PATCH", route, `{"name":"  new name  "}`, admin)
	var renamed gallery.Album
	if got.Code != 200 || json.Unmarshal(got.Body.Bytes(), &renamed) != nil || renamed.Name != "new name" || renamed.Count != 1 {
		t.Fatalf("rename response: %d %s", got.Code, got.Body.String())
	}
	if got := call("DELETE", itemRoute, "", admin); got.Code != 200 {
		t.Fatalf("remove from album: %d %s", got.Code, got.Body.String())
	}
	if got := call("DELETE", itemRoute, "", admin); got.Code != 404 {
		t.Fatalf("missing album membership: %d %s", got.Code, got.Body.String())
	}
	if err := photos.AddToAlbum(album.ID, assetID); err != nil {
		t.Fatal(err)
	}
	if got := call("DELETE", route, "", admin); got.Code != 200 {
		t.Fatalf("delete album: %d %s", got.Code, got.Body.String())
	}
	if got := call("DELETE", route, "", admin); got.Code != 404 {
		t.Fatalf("delete missing album: %d %s", got.Code, got.Body.String())
	}
	if got := call("PATCH", "/api/v1/photos/albums/invalid", `{"name":"new"}`, admin); got.Code != 400 {
		t.Fatalf("invalid album id: %d", got.Code)
	}
	asset, err := photos.Asset(assetID)
	if err != nil || !asset.Favorite {
		t.Fatalf("album mutation changed original metadata: %+v %v", asset, err)
	}
	file, _, err := storage.Read("photo.jpg")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	data, err := io.ReadAll(file)
	if err != nil || string(data) != original {
		t.Fatalf("album mutation changed original bytes: %q %v", data, err)
	}
}
