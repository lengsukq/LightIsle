package server

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	_ "github.com/mattn/go-sqlite3"
)

type galleryFilterHarness struct {
	handler http.Handler
	admin   string
	photos  *gallery.Library
}

func TestGalleryTimelineCoversUnloadedAuthorizedMonths(t *testing.T) {
	h := newGalleryFilterHarness(t)
	code, payload := h.call(t, "/api/v1/photos/timeline")
	if code != http.StatusOK {
		t.Fatalf("timeline status = %d", code)
	}
	months, ok := payload["months"].([]any)
	if !ok || len(months) < 2 {
		t.Fatalf("timeline months = %v", payload)
	}
	count := 0
	for _, value := range months {
		item := value.(map[string]any)
		if got := int(item["firstIndex"].(float64)); got != count {
			t.Fatalf("month cursor = %d, want %d", got, count)
		}
		count += int(item["count"].(float64))
	}
	if count != 4 {
		t.Fatalf("timeline count = %d, want 4", count)
	}
}

func newGalleryFilterHarness(t *testing.T) *galleryFilterHarness {
	t.Helper()
	dataDir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { accounts.Close() })
	if err := accounts.Setup("owner", "valid-owner-password"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "valid-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	shared, err := files.NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { shared.Close() })
	today := time.Now()
	// 40 days back guarantees a different month-day than today, unlike a
	// whole-year offset which "on this day" would legitimately match.
	old := today.AddDate(0, 0, -40)
	for dir, moment := range map[string]time.Time{"trip": today, "old": old} {
		if err := shared.Mkdir(dir); err != nil {
			t.Fatal(err)
		}
		for _, name := range []string{"beach.jpg", "clip.mp4"} {
			if _, err := shared.Upload(dir+"/"+name, bytes.NewBufferString("fixture-"+dir+"-"+name)); err != nil {
				t.Fatal(err)
			}
			physical := filepath.Join(dataDir, "SharedFiles", dir, name)
			if err := os.Chtimes(physical, moment, moment); err != nil {
				t.Fatal(err)
			}
		}
	}
	photos, err := gallery.Open(dataDir, shared)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { photos.Close() })
	films, err := cinema.Open(dataDir, shared)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { films.Close() })
	if err := photos.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for photos.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if state := photos.Status(); state.Running || state.LastError != "" {
		t.Fatalf("gallery scan failed: %+v", state)
	}
	// Seed one located asset directly; the extraction pipeline has its own
	// coverage in the gallery package, the endpoint only needs coordinates.
	seed, err := sql.Open("sqlite3", filepath.Join(dataDir, "gallery.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := seed.Exec(`UPDATE assets SET gps_lat=?,gps_lon=? WHERE path=?`, 31.2304, 121.4737, "trip/beach.jpg"); err != nil {
		seed.Close()
		t.Fatal(err)
	}
	seed.Close()
	return &galleryFilterHarness{handler: NewWithCinema("", accounts, shared, photos, films), admin: admin, photos: photos}
}

func (h *galleryFilterHarness) call(t *testing.T, route string) (int, map[string]any) {
	t.Helper()
	r := httptest.NewRequest("GET", route, nil)
	r.AddCookie(&http.Cookie{Name: sessionCookie, Value: h.admin})
	w := httptest.NewRecorder()
	h.handler.ServeHTTP(w, r)
	var body map[string]any
	if w.Code == 200 {
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatalf("response not json: %v", err)
		}
	}
	return w.Code, body
}

func assetPaths(body map[string]any) []string {
	paths := []string{}
	for _, raw := range body["assets"].([]any) {
		paths = append(paths, raw.(map[string]any)["path"].(string))
	}
	return paths
}

func TestGalleryListFiltersKindQueryOnThisDayAndIDs(t *testing.T) {
	h := newGalleryFilterHarness(t)

	code, body := h.call(t, "/api/v1/photos?limit=60")
	if code != 200 || len(assetPaths(body)) != 4 {
		t.Fatalf("baseline listing = %d %v", code, body)
	}

	code, body = h.call(t, "/api/v1/photos?type=photo")
	if code != 200 {
		t.Fatalf("type filter status %d", code)
	}
	for _, path := range assetPaths(body) {
		if path[len(path)-4:] == ".mp4" {
			t.Fatalf("type=photo returned a video: %s", path)
		}
	}

	code, body = h.call(t, "/api/v1/photos?q=beach")
	if code != 200 || len(assetPaths(body)) != 2 {
		t.Fatalf("query filter = %d %v", code, assetPaths(body))
	}
	for _, path := range assetPaths(body) {
		if path != "trip/beach.jpg" && path != "old/beach.jpg" {
			t.Fatalf("query filter returned wrong asset: %s", path)
		}
	}
	// % must match literally, not act as a wildcard.
	code, body = h.call(t, "/api/v1/photos?q=%25")
	if code != 200 || len(assetPaths(body)) != 0 {
		t.Fatalf("percent literal filter = %d %v", code, assetPaths(body))
	}

	code, body = h.call(t, "/api/v1/photos?onThisDay=1")
	if code != 200 {
		t.Fatalf("onThisDay status %d", code)
	}
	paths := assetPaths(body)
	if len(paths) == 0 || len(paths) > 2 {
		t.Fatalf("onThisDay returned %d assets: %v", len(paths), paths)
	}
	for _, path := range paths {
		if path[:4] != "trip" {
			t.Fatalf("onThisDay returned an old asset: %s", path)
		}
	}

	var tripPhotoID int64
	for _, asset := range h.listAssets(t) {
		if asset.Path == "trip/beach.jpg" {
			tripPhotoID = asset.ID
		}
	}
	code, body = h.call(t, fmt.Sprintf("/api/v1/photos?ids=%d", tripPhotoID))
	if code != 200 || len(assetPaths(body)) != 1 || assetPaths(body)[0] != "trip/beach.jpg" {
		t.Fatalf("ids filter = %d %v", code, assetPaths(body))
	}

	for route, wantCode := range map[string]int{
		"/api/v1/photos?type=audio":            400,
		"/api/v1/photos?ids=0":                 400,
		"/api/v1/photos?ids=1,x":               400,
		"/api/v1/photos?q=" + repeat("x", 129): 400,
	} {
		if code, _ := h.call(t, route); code != wantCode {
			t.Fatalf("%s status = %d, want %d", route, code, wantCode)
		}
	}
}

func (h *galleryFilterHarness) listAssets(t *testing.T) []gallery.Asset {
	t.Helper()
	assets, _, err := h.photos.List(0, 60, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	return assets
}

func repeat(text string, count int) string {
	return strings.Repeat(text, count)
}

func TestGalleryGeoEndpointReturnsLocatedPoints(t *testing.T) {
	h := newGalleryFilterHarness(t)
	code, body := h.call(t, "/api/v1/photos/geo")
	if code != 200 {
		t.Fatalf("geo status %d", code)
	}
	points, _ := body["points"].([]any)
	if len(points) != 1 {
		t.Fatalf("points = %v", body)
	}
	point := points[0].(map[string]any)
	if point["id"].(float64) == 0 || point["type"] != "photo" {
		t.Fatalf("point = %v", point)
	}
	if lat := point["lat"].(float64); lat < 31.2 || lat > 31.3 {
		t.Fatalf("lat = %v", lat)
	}
	if lon := point["lon"].(float64); lon < 121.4 || lon > 121.5 {
		t.Fatalf("lon = %v", lon)
	}
	if _, hasPath := point["path"]; hasPath {
		t.Fatal("geo payload must not expose paths")
	}
	if body["total"].(float64) != 1 || body["truncated"].(bool) {
		t.Fatalf("geo counters wrong: %v", body)
	}
}
