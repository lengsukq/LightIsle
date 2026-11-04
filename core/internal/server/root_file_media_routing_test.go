package server

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

func TestRootFileWritesSearchZIPAndUploadSessionsStayRootScoped(t *testing.T) {
	f := newRootRoutingFixture(t)
	missingGeneration := f.callWithGeneration(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/files/folders"), `{"path":"missing-generation"}`, false, "")
	if missingGeneration.Code != http.StatusPreconditionRequired || !strings.Contains(missingGeneration.Body.String(), "root_generation_required") {
		t.Fatalf("write without root generation = %d %s", missingGeneration.Code, missingGeneration.Body.String())
	}
	staleGeneration := f.callWithGeneration(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/files/folders"), `{"path":"stale-generation"}`, false, strconv.FormatUint(f.rootA.Generation+1, 10))
	if staleGeneration.Code != http.StatusConflict || !strings.Contains(staleGeneration.Body.String(), "root_generation_changed") {
		t.Fatalf("write with stale root generation = %d %s", staleGeneration.Code, staleGeneration.Body.String())
	}
	invalidGeneration := f.callWithGeneration(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/files/folders"), `{"path":"invalid-generation"}`, false, "not-a-generation")
	if invalidGeneration.Code != http.StatusBadRequest || !strings.Contains(invalidGeneration.Body.String(), "invalid_root_generation") {
		t.Fatalf("write with invalid root generation = %d %s", invalidGeneration.Code, invalidGeneration.Body.String())
	}
	if f.services[f.rootA.ID] != nil {
		t.Fatal("rejected generation request created root services")
	}
	for _, name := range []string{"gallery-root-" + f.rootA.ID + ".sqlite", "cinema-root-" + f.rootA.ID + ".sqlite", "tasks-root-" + f.rootA.ID + ".sqlite"} {
		if _, err := os.Stat(filepath.Join(f.dataDir, name)); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("rejected generation request initialized %s: %v", name, err)
		}
	}
	for _, item := range []struct{ root, name, body string }{
		{f.pathA, "same.txt", "root-a-original"}, {f.pathB, "same.txt", "root-b-original"},
		{f.pathA, "find-a-needle.txt", "a"}, {f.pathB, "find-b-needle.txt", "b"},
		{f.pathA, "bundle/only-a.txt", "a-zip"}, {f.pathB, "bundle/only-b.txt", "b-zip"},
	} {
		fullPath := filepath.Join(item.root, filepath.FromSlash(item.name))
		if err := os.MkdirAll(filepath.Dir(fullPath), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(fullPath, []byte(item.body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, root := range []string{f.pathA, f.pathB} {
		if err := os.Mkdir(filepath.Join(root, "uploads"), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootA.ID, ".", false); err != nil {
		t.Fatal(err)
	}
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootB.ID, ".", true); err != nil {
		t.Fatal(err)
	}
	// A permissive legacy grant must not affect any v2 root's capability hint
	// or mutation check.
	if err := f.accounts.SetFileGrant(f.admin, f.memberID, ".", true); err != nil {
		t.Fatal(err)
	}
	for _, item := range []struct {
		rootID         string
		wantCanWrite   bool
		wantSearchPath string
	}{
		{f.rootA.ID, false, "find-a-needle.txt"},
		{f.rootB.ID, true, "find-b-needle.txt"},
	} {
		listed := f.call(f.member, http.MethodGet, rootRoute(item.rootID, "/files?path=."), "")
		if listed.Code != http.StatusOK {
			t.Fatalf("list root %s: %d %s", item.rootID, listed.Code, listed.Body.String())
		}
		var page struct {
			CanWrite bool `json:"canWrite"`
		}
		if err := json.Unmarshal(listed.Body.Bytes(), &page); err != nil || page.CanWrite != item.wantCanWrite {
			t.Fatalf("root %s write hint = %+v, err=%v", item.rootID, page, err)
		}
		search := f.call(f.member, http.MethodGet, rootRoute(item.rootID, "/files/search?path=.&query=needle"), "")
		if search.Code != http.StatusOK || !bytes.Contains(search.Body.Bytes(), []byte(item.wantSearchPath)) {
			t.Fatalf("search root %s: %d %s", item.rootID, search.Code, search.Body.String())
		}
		wrongPath := "find-a-needle.txt"
		if item.rootID == f.rootA.ID {
			wrongPath = "find-b-needle.txt"
		}
		if bytes.Contains(search.Body.Bytes(), []byte(wrongPath)) {
			t.Fatalf("search root %s leaked sibling result %s: %s", item.rootID, wrongPath, search.Body.String())
		}
		created := f.call(f.admin, http.MethodPut, rootRoute(item.rootID, "/files/content?path=admin-created.txt"), "admin-"+item.rootID)
		if created.Code != http.StatusCreated {
			t.Fatalf("admin write root %s: %d %s", item.rootID, created.Code, created.Body.String())
		}
	}
	denied := f.call(f.member, http.MethodPut, rootRoute(f.rootA.ID, "/files/content?path=member-created.txt"), "denied")
	if denied.Code != http.StatusForbidden {
		t.Fatalf("legacy grant enabled root A write: %d %s", denied.Code, denied.Body.String())
	}
	created := f.call(f.member, http.MethodPut, rootRoute(f.rootB.ID, "/files/content?path=member-created.txt"), "root-b-member")
	if created.Code != http.StatusCreated {
		t.Fatalf("root B member write: %d %s", created.Code, created.Body.String())
	}
	for _, item := range []struct{ rootID, body string }{
		{f.rootA.ID, "admin-" + f.rootA.ID},
		{f.rootB.ID, "admin-" + f.rootB.ID},
	} {
		response := f.call(f.member, http.MethodGet, rootRoute(item.rootID, "/files/content?path=admin-created.txt"), "")
		if response.Code != http.StatusOK || response.Body.String() != item.body {
			t.Fatalf("read same relative path from root %s: %d %q", item.rootID, response.Code, response.Body.String())
		}
	}
	readA := f.call(f.admin, http.MethodGet, rootRoute(f.rootA.ID, "/files/content?path=same.txt"), "")
	readB := f.call(f.admin, http.MethodGet, rootRoute(f.rootB.ID, "/files/content?path=same.txt"), "")
	if readA.Body.String() != "root-a-original" || readB.Body.String() != "root-b-original" {
		t.Fatalf("same relative path crossed roots: A=%q B=%q", readA.Body.String(), readB.Body.String())
	}
	for _, item := range []struct{ rootID, expected, excluded string }{
		{f.rootA.ID, "only-a.txt", "only-b.txt"}, {f.rootB.ID, "only-b.txt", "only-a.txt"},
	} {
		archive := f.call(f.member, http.MethodGet, rootRoute(item.rootID, "/files/archive?path=bundle"), "")
		if archive.Code != http.StatusOK {
			t.Fatalf("archive root %s: %d %s", item.rootID, archive.Code, archive.Body.String())
		}
		reader, err := zip.NewReader(bytes.NewReader(archive.Body.Bytes()), int64(archive.Body.Len()))
		if err != nil {
			t.Fatalf("read archive root %s: %v", item.rootID, err)
		}
		var names []string
		for _, entry := range reader.File {
			names = append(names, entry.Name)
		}
		joined := strings.Join(names, ",")
		if !strings.Contains(joined, item.expected) || strings.Contains(joined, item.excluded) {
			t.Fatalf("archive root %s contains wrong sibling paths: %v", item.rootID, names)
		}
	}

	begin := f.call(f.member, http.MethodPost, rootRoute(f.rootB.ID, "/uploads"), `{"path":"uploads/pending.bin","size":5}`)
	if begin.Code != http.StatusCreated {
		t.Fatalf("begin upload root B: %d %s", begin.Code, begin.Body.String())
	}
	var upload files.UploadState
	if err := json.Unmarshal(begin.Body.Bytes(), &upload); err != nil || upload.ID == "" {
		t.Fatalf("upload response %s: %v", begin.Body.String(), err)
	}
	for _, action := range []struct{ method, suffix string }{
		{http.MethodPost, "/uploads/" + upload.ID + "/complete"},
		{http.MethodDelete, "/uploads/" + upload.ID},
	} {
		crossRoot := f.call(f.member, action.method, rootRoute(f.rootA.ID, action.suffix), "")
		if crossRoot.Code != http.StatusNotFound {
			t.Errorf("cross-root upload %s was accepted: %d %s", action.method, crossRoot.Code, crossRoot.Body.String())
		}
	}
	adminRootA := f.call(f.admin, http.MethodGet, rootRoute(f.rootA.ID, "/admin/uploads"), "")
	adminRootB := f.call(f.admin, http.MethodGet, rootRoute(f.rootB.ID, "/admin/uploads"), "")
	var adminListA, adminListB struct {
		Uploads []adminUploadItem `json:"uploads"`
	}
	if err := json.Unmarshal(adminRootA.Body.Bytes(), &adminListA); err != nil || len(adminListA.Uploads) != 0 {
		t.Fatalf("root A admin uploads include root B session: %+v err=%v status=%d", adminListA, err, adminRootA.Code)
	}
	if err := json.Unmarshal(adminRootB.Body.Bytes(), &adminListB); err != nil || len(adminListB.Uploads) != 1 || !adminListB.Uploads[0].OwnerCanWrite {
		t.Fatalf("root B admin upload grant hint incorrect: %+v err=%v status=%d", adminListB, err, adminRootB.Code)
	}
	chunk := httptest.NewRequest(http.MethodPatch, rootRoute(f.rootB.ID, "/uploads/"+upload.ID), strings.NewReader("hello"))
	chunk.Header.Set("X-LightIsle-Request", "1")
	chunk.Header.Set(rootGenerationHeader, strconv.FormatUint(f.rootB.Generation, 10))
	chunk.Header.Set("X-Upload-Offset", "0")
	chunk.AddCookie(&http.Cookie{Name: sessionCookie, Value: f.member})
	chunkResponse := httptest.NewRecorder()
	f.server.ServeHTTP(chunkResponse, chunk)
	if chunkResponse.Code != http.StatusOK {
		t.Fatalf("append root B upload: %d %s", chunkResponse.Code, chunkResponse.Body.String())
	}
	complete := f.call(f.member, http.MethodPost, rootRoute(f.rootB.ID, "/uploads/"+upload.ID+"/complete"), "")
	if complete.Code != http.StatusOK {
		t.Fatalf("complete root B upload: %d %s", complete.Code, complete.Body.String())
	}
	uploaded := f.call(f.admin, http.MethodGet, rootRoute(f.rootB.ID, "/files/content?path=uploads/pending.bin"), "")
	if uploaded.Code != http.StatusOK || uploaded.Body.String() != "hello" {
		t.Fatalf("root B upload destination: %d %q", uploaded.Code, uploaded.Body.String())
	}
	if _, err := os.Stat(filepath.Join(f.pathA, "uploads", "pending.bin")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("root B upload appeared in root A: %v", err)
	}
}

func TestRootMediaIDsAlbumsFavoritesAndRebindGenerationStayScoped(t *testing.T) {
	f := newRootRoutingFixture(t)
	for _, item := range []struct{ name, data string }{
		{"visible/Photo.jpg", "visible-photo-v1"},
		{"secret/Hidden.jpg", "hidden-photo-v1"},
		{"visible/VisibleMovie.mkv", "visible-movie-v1"},
		{"secret/HiddenMovie.mkv", "hidden-movie-v1"},
	} {
		fullPath := filepath.Join(f.pathA, filepath.FromSlash(item.name))
		if err := os.MkdirAll(filepath.Dir(fullPath), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(fullPath, []byte(item.data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootA.ID, "visible", false); err != nil {
		t.Fatal(err)
	}
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootB.ID, ".", false); err != nil {
		t.Fatal(err)
	}
	startRootScans(t, f, f.rootA.ID)
	photos := f.call(f.admin, http.MethodGet, rootRoute(f.rootA.ID, "/photos?limit=120"), "")
	if photos.Code != http.StatusOK {
		t.Fatalf("list indexed photos: %d %s", photos.Code, photos.Body.String())
	}
	var photoPage struct {
		Assets []struct {
			ID   int64  `json:"id"`
			Path string `json:"path"`
		} `json:"assets"`
	}
	if err := json.Unmarshal(photos.Body.Bytes(), &photoPage); err != nil {
		t.Fatal(err)
	}
	var visiblePhotoID, secretPhotoID int64
	for _, item := range photoPage.Assets {
		switch item.Path {
		case "visible/Photo.jpg":
			visiblePhotoID = item.ID
		case "secret/Hidden.jpg":
			secretPhotoID = item.ID
		}
	}
	if visiblePhotoID == 0 || secretPhotoID == 0 {
		t.Fatalf("missing indexed photos: %+v", photoPage.Assets)
	}
	cinemaList := f.call(f.admin, http.MethodGet, rootRoute(f.rootA.ID, "/cinema?limit=120"), "")
	if cinemaList.Code != http.StatusOK {
		t.Fatalf("list indexed films: %d %s", cinemaList.Code, cinemaList.Body.String())
	}
	var filmPage struct {
		Films []struct {
			ID    int64   `json:"id"`
			Path  string  `json:"path"`
			Title string  `json:"title"`
			Pos   float64 `json:"position"`
		} `json:"films"`
	}
	if err := json.Unmarshal(cinemaList.Body.Bytes(), &filmPage); err != nil {
		t.Fatal(err)
	}
	var visibleFilmID, secretFilmID int64
	for _, item := range filmPage.Films {
		if item.Path == "visible/VisibleMovie.mkv" {
			visibleFilmID = item.ID
		}
		if item.Path == "secret/HiddenMovie.mkv" {
			secretFilmID = item.ID
		}
	}
	if visibleFilmID == 0 || secretFilmID == 0 {
		t.Fatalf("missing indexed films: %+v", filmPage.Films)
	}
	for _, item := range []struct {
		path, missingBody string
	}{
		{rootRoute(f.rootA.ID, "/photos/"+strconv.FormatInt(secretPhotoID, 10)+"/thumbnail"), `{"error":"not_found"}`},
		{rootRoute(f.rootA.ID, "/photos/999999/thumbnail"), `{"error":"not_found"}`},
		{rootRoute(f.rootA.ID, "/cinema/"+strconv.FormatInt(secretFilmID, 10)), `{"error":"film_not_found"}`},
		{rootRoute(f.rootA.ID, "/cinema/999999"), `{"error":"film_not_found"}`},
	} {
		response := f.call(f.member, http.MethodGet, item.path, "")
		if response.Code != http.StatusNotFound || strings.TrimSpace(response.Body.String()) != item.missingBody {
			t.Errorf("hidden media ID response for %s = %d %s", item.path, response.Code, response.Body.String())
		}
	}
	visibleFilm := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/cinema/"+strconv.FormatInt(visibleFilmID, 10)), "")
	if visibleFilm.Code != http.StatusOK || !bytes.Contains(visibleFilm.Body.Bytes(), []byte("visible/VisibleMovie.mkv")) {
		t.Fatalf("visible media ID unavailable: %d %s", visibleFilm.Code, visibleFilm.Body.String())
	}
	for _, route := range []string{
		rootRoute(f.rootA.ID, "/photos/"+strconv.FormatInt(secretPhotoID, 10)+"/personal-favorite"),
		rootRoute(f.rootA.ID, "/photos/"+strconv.FormatInt(secretPhotoID, 10)+"/favorite"),
	} {
		response := f.call(f.member, http.MethodPost, route, `{"favorite":true}`)
		if response.Code != http.StatusNotFound {
			t.Errorf("hidden photo mutation leaked ID %s: %d %s", route, response.Code, response.Body.String())
		}
	}
	createAlbum := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/photos/private-albums"), `{"name":"Personal"}`)
	if createAlbum.Code != http.StatusCreated {
		t.Fatalf("create root A private album: %d %s", createAlbum.Code, createAlbum.Body.String())
	}
	var album gallery.Album
	if err := json.Unmarshal(createAlbum.Body.Bytes(), &album); err != nil || album.ID <= 0 {
		t.Fatalf("private album response: %+v %v", album, err)
	}
	addVisible := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/photos/private-albums/"+strconv.FormatInt(album.ID, 10)+"/items"), `{"assetId":`+strconv.FormatInt(visiblePhotoID, 10)+`}`)
	if addVisible.Code != http.StatusOK {
		t.Fatalf("add visible asset to private album: %d %s", addVisible.Code, addVisible.Body.String())
	}
	addSecret := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/photos/private-albums/"+strconv.FormatInt(album.ID, 10)+"/items"), `{"assetId":`+strconv.FormatInt(secretPhotoID, 10)+`}`)
	if addSecret.Code != http.StatusNotFound {
		t.Fatalf("hidden asset entered private album: %d %s", addSecret.Code, addSecret.Body.String())
	}
	markFavorite := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/photos/"+strconv.FormatInt(visiblePhotoID, 10)+"/personal-favorite"), `{"favorite":true}`)
	if markFavorite.Code != http.StatusOK {
		t.Fatalf("mark root A personal favorite: %d %s", markFavorite.Code, markFavorite.Body.String())
	}
	rootBAlbums := f.call(f.member, http.MethodGet, rootRoute(f.rootB.ID, "/photos/private-albums"), "")
	if rootBAlbums.Code != http.StatusOK || !bytes.Contains(rootBAlbums.Body.Bytes(), []byte(`"albums":[]`)) {
		t.Fatalf("root A private album visible in root B: %d %s", rootBAlbums.Code, rootBAlbums.Body.String())
	}
	rootBCrossAlbum := f.call(f.member, http.MethodPatch, rootRoute(f.rootB.ID, "/photos/private-albums/"+strconv.FormatInt(album.ID, 10)), `{"name":"Cross-root"}`)
	if rootBCrossAlbum.Code != http.StatusNotFound {
		t.Fatalf("root B renamed root A private album: %d %s", rootBCrossAlbum.Code, rootBCrossAlbum.Body.String())
	}
	rootBCrossFavorite := f.call(f.member, http.MethodPost, rootRoute(f.rootB.ID, "/photos/"+strconv.FormatInt(visiblePhotoID, 10)+"/personal-favorite"), `{"favorite":true}`)
	if rootBCrossFavorite.Code != http.StatusNotFound {
		t.Fatalf("root B accepted root A photo ID: %d %s", rootBCrossFavorite.Code, rootBCrossFavorite.Body.String())
	}
	rootBCrossFilm := f.call(f.member, http.MethodGet, rootRoute(f.rootB.ID, "/cinema/"+strconv.FormatInt(visibleFilmID, 10)), "")
	if rootBCrossFilm.Code != http.StatusNotFound {
		t.Fatalf("root B accepted root A film ID: %d %s", rootBCrossFilm.Code, rootBCrossFilm.Body.String())
	}
	rootAPersonal := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/photos?personal=1"), "")
	rootBPersonal := f.call(f.member, http.MethodGet, rootRoute(f.rootB.ID, "/photos?personal=1"), "")
	if rootAPersonal.Code != http.StatusOK || !bytes.Contains(rootAPersonal.Body.Bytes(), []byte("visible/Photo.jpg")) ||
		rootBPersonal.Code != http.StatusOK || bytes.Contains(rootBPersonal.Body.Bytes(), []byte("Photo.jpg")) {
		t.Fatalf("personal favorites crossed roots: A=%d %s B=%d %s", rootAPersonal.Code, rootAPersonal.Body.String(), rootBPersonal.Code, rootBPersonal.Body.String())
	}
	manualTitle := f.call(f.admin, http.MethodPatch, rootRoute(f.rootA.ID, "/cinema/"+strconv.FormatInt(visibleFilmID, 10)), `{"title":"Old Root Manual Title"}`)
	if manualTitle.Code != http.StatusOK {
		t.Fatalf("set manual metadata: %d %s", manualTitle.Code, manualTitle.Body.String())
	}
	progress := f.call(f.admin, http.MethodPut, rootRoute(f.rootA.ID, "/cinema/"+strconv.FormatInt(visibleFilmID, 10)+"/progress"), `{"position":33,"duration":120}`)
	if progress.Code != http.StatusOK {
		t.Fatalf("save watch progress: %d %s", progress.Code, progress.Body.String())
	}

	// Replace the physical directory at the same pathname. Root ID and member
	// ACLs must NEVER follow a new inode. Explicitly remounting the ORIGINAL
	// directory at a new path then advances generation without cross-ACL leaks.
	oldPath := f.pathA + "-old"
	if err := os.Rename(f.pathA, oldPath); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(f.pathA, 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := f.registry.Rebind(context.Background(), f.rootA.ID, f.pathA); !errors.Is(err, roots.ErrDifferentDirectory) {
		t.Fatalf("a replacement inode inherited original root permissions: %v", err)
	}
	for _, item := range []struct{ name, data string }{
		{"visible/Photo.jpg", "visible-photo-v2"},
		{"secret/Hidden.jpg", "hidden-photo-v2"},
		{"visible/VisibleMovie.mkv", "visible-movie-v2"},
		{"secret/HiddenMovie.mkv", "hidden-movie-v2"},
	} {
		fullPath := filepath.Join(oldPath, filepath.FromSlash(item.name))
		if err := os.MkdirAll(filepath.Dir(fullPath), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(fullPath, []byte(item.data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	newRoot, err := f.registry.Rebind(context.Background(), f.rootA.ID, oldPath)
	if err != nil {
		t.Fatalf("rebind root at same path: %v", err)
	}
	if newRoot.Generation == f.rootA.Generation {
		t.Fatalf("rebind did not advance root generation: old=%d new=%d", f.rootA.Generation, newRoot.Generation)
	}
	staleRead := f.call(f.admin, http.MethodGet, rootRoute(f.rootA.ID, "/photos?rootGeneration="+strconv.FormatUint(f.rootA.Generation, 10)), "")
	if staleRead.Code != http.StatusConflict || !strings.Contains(staleRead.Body.String(), "root_generation_changed") {
		t.Fatalf("pre-rebind media URL was accepted after rebind: %d %s", staleRead.Code, staleRead.Body.String())
	}
	staleWrite := f.callWithGeneration(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/files/folders"), `{"path":"stale-generation-write"}`, false, strconv.FormatUint(f.rootA.Generation, 10))
	if staleWrite.Code != http.StatusConflict || !strings.Contains(staleWrite.Body.String(), "root_generation_changed") {
		t.Fatalf("pre-rebind browser write was accepted after rebind: %d %s", staleWrite.Code, staleWrite.Body.String())
	}
	if _, err := os.Stat(filepath.Join(oldPath, "stale-generation-write")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale write changed rebound root: %v", err)
	}
	newPhotos := f.call(f.admin, http.MethodGet, rootRoute(f.rootA.ID, "/photos?limit=120"), "")
	newFilms := f.call(f.admin, http.MethodGet, rootRoute(f.rootA.ID, "/cinema?limit=120"), "")
	if newPhotos.Code != http.StatusOK || !bytes.Contains(newPhotos.Body.Bytes(), []byte(`"assets":[]`)) {
		t.Fatalf("old photo rows visible after rebind before scan: %d %s", newPhotos.Code, newPhotos.Body.String())
	}
	if newFilms.Code != http.StatusOK || !bytes.Contains(newFilms.Body.Bytes(), []byte(`"films":[]`)) {
		t.Fatalf("old film rows visible after rebind before scan: %d %s", newFilms.Code, newFilms.Body.String())
	}
	startRootScans(t, f, f.rootA.ID)
	newPhotos = f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/photos?personal=1&limit=120"), "")
	newFilms = f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/cinema?limit=120"), "")
	if newPhotos.Code != http.StatusOK || bytes.Contains(newPhotos.Body.Bytes(), []byte("Photo.jpg")) {
		t.Fatalf("old personal favorite returned for rebound root: %d %s", newPhotos.Code, newPhotos.Body.String())
	}
	if newFilms.Code != http.StatusOK || bytes.Contains(newFilms.Body.Bytes(), []byte("Old Root Manual Title")) || bytes.Contains(newFilms.Body.Bytes(), []byte(`"position":33`)) {
		t.Fatalf("old metadata/progress returned for rebound root: %d %s", newFilms.Code, newFilms.Body.String())
	}
	newAlbums := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/photos/private-albums"), "")
	if newAlbums.Code != http.StatusOK || !bytes.Contains(newAlbums.Body.Bytes(), []byte(`"albums":[]`)) {
		t.Fatalf("old private album returned for rebound root: %d %s", newAlbums.Code, newAlbums.Body.String())
	}
	for _, generation := range []uint64{f.rootA.Generation, newRoot.Generation} {
		cacheDir := filepath.Join(f.dataDir, "thumbnails-root-"+f.rootA.ID+"-generation-"+strconv.FormatUint(generation, 10))
		if info, err := os.Stat(cacheDir); err != nil || !info.IsDir() {
			t.Errorf("generation %d thumbnail cache missing or shared: %s (%v)", generation, cacheDir, err)
		}
	}
}

func startRootScans(t *testing.T, f *rootRoutingFixture, rootID string) {
	t.Helper()
	for _, route := range []string{"/photos/scan", "/cinema/scan"} {
		response := f.call(f.admin, http.MethodPost, rootRoute(rootID, route), "")
		if response.Code != http.StatusAccepted {
			t.Fatalf("start root %s scan %s: %d %s", rootID, route, response.Code, response.Body.String())
		}
	}
	services := f.services[rootID]
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if services != nil && !services.Gallery.Status().Running && !services.Cinema.Status().Running &&
			services.Gallery.Status().LastDone > 0 && services.Cinema.Status().LastDone > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if services == nil || services.Gallery.Status().Running || services.Cinema.Status().Running ||
		services.Gallery.Status().LastDone == 0 || services.Cinema.Status().LastDone == 0 {
		t.Fatalf("root %s scan did not finish: gallery=%+v cinema=%+v", rootID, services.Gallery.Status(), services.Cinema.Status())
	}
	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		f.server.mu.Lock()
		runtime := f.server.runtimes[rootID]
		f.server.mu.Unlock()
		if runtime == nil {
			return
		}
		runtime.scanMu.Lock()
		active := len(runtime.scans)
		runtime.scanMu.Unlock()
		if active == 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("root scan lease was not released")
}

type blockingRootMediaWorker struct {
	entered chan struct{}
	once    sync.Once
}

func newBlockingRootMediaWorker() *blockingRootMediaWorker {
	return &blockingRootMediaWorker{entered: make(chan struct{})}
}

func (w *blockingRootMediaWorker) Probe(ctx context.Context, _ *os.File, _ string) (mediaworker.Metadata, error) {
	w.once.Do(func() { close(w.entered) })
	<-ctx.Done()
	return mediaworker.Metadata{}, ctx.Err()
}

func (w *blockingRootMediaWorker) Poster(context.Context, *os.File, string, string) (mediaworker.Metadata, error) {
	return mediaworker.Metadata{}, mediaworker.ErrUnavailable
}

func TestRootTaskCancellationDoesNotCancelSiblingRootScan(t *testing.T) {
	f := newRootRoutingFixture(t)
	for _, root := range []string{f.pathA, f.pathB} {
		if err := os.WriteFile(filepath.Join(root, "blocked.heic"), []byte("worker input"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootA.ID, ".", false); err != nil {
		t.Fatal(err)
	}
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootB.ID, ".", false); err != nil {
		t.Fatal(err)
	}
	for _, rootID := range []string{f.rootA.ID, f.rootB.ID} {
		response := f.call(f.admin, http.MethodGet, rootRoute(rootID, "/photos/status"), "")
		if response.Code != http.StatusOK {
			t.Fatalf("initialize gallery for root %s: %d %s", rootID, response.Code, response.Body.String())
		}
	}
	workerA := newBlockingRootMediaWorker()
	workerB := newBlockingRootMediaWorker()
	f.services[f.rootA.ID].Gallery.SetMediaWorker(workerA)
	f.services[f.rootB.ID].Gallery.SetMediaWorker(workerB)
	for _, rootID := range []string{f.rootA.ID, f.rootB.ID} {
		response := f.call(f.admin, http.MethodPost, rootRoute(rootID, "/photos/scan"), "")
		if response.Code != http.StatusAccepted {
			t.Fatalf("start root %s gallery scan: %d %s", rootID, response.Code, response.Body.String())
		}
	}
	for _, item := range []struct {
		rootID  string
		entered <-chan struct{}
	}{{f.rootA.ID, workerA.entered}, {f.rootB.ID, workerB.entered}} {
		select {
		case <-item.entered:
		case <-time.After(3 * time.Second):
			t.Fatalf("root %s scanner never reached blocking worker", item.rootID)
		}
	}
	cancelA := f.call(f.admin, http.MethodPost, rootRoute(f.rootA.ID, "/tasks/gallery/cancel"), "")
	if cancelA.Code != http.StatusOK {
		t.Fatalf("cancel root A scan: %d %s", cancelA.Code, cancelA.Body.String())
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && f.services[f.rootA.ID].Gallery.Status().Running {
		time.Sleep(5 * time.Millisecond)
	}
	if f.services[f.rootA.ID].Gallery.Status().Running {
		t.Fatal("root A scan did not stop after its cancellation")
	}
	if !f.services[f.rootB.ID].Gallery.Status().Running {
		t.Fatal("cancelling root A also stopped root B scan")
	}
	cancelB := f.call(f.admin, http.MethodPost, rootRoute(f.rootB.ID, "/tasks/gallery/cancel"), "")
	if cancelB.Code != http.StatusOK {
		t.Fatalf("cancel root B scan: %d %s", cancelB.Code, cancelB.Body.String())
	}
	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && f.services[f.rootB.ID].Gallery.Status().Running {
		time.Sleep(5 * time.Millisecond)
	}
	if f.services[f.rootB.ID].Gallery.Status().Running {
		t.Fatal("root B scan did not stop after its own cancellation")
	}
}
