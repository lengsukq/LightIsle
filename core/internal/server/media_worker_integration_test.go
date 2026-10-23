package server

import (
	"bytes"
	"image/jpeg"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

// This test is opt-in because CI and non-macOS development machines may not
// have the signed native worker or Apple's image codecs. The integration
// script supplies locally generated fixtures and the already-built worker.
func TestMediaWorkerHTTPIntegration(t *testing.T) {
	workerPath := os.Getenv("LIGHTISLE_TEST_MEDIA_WORKER")
	heicPath := os.Getenv("LIGHTISLE_TEST_HEIC")
	mp4Path := os.Getenv("LIGHTISLE_TEST_MP4")
	if workerPath == "" || heicPath == "" || mp4Path == "" {
		t.Skip("set LIGHTISLE_TEST_MEDIA_WORKER, LIGHTISLE_TEST_HEIC, and LIGHTISLE_TEST_MP4 to run the native integration")
	}
	for _, path := range []string{workerPath, heicPath, mp4Path} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("integration input %q: %v", path, err)
		}
	}
	if _, err := os.Stat("/usr/bin/sips"); err != nil {
		t.Skip("Apple sips is required for the HEIC photo thumbnail endpoint")
	}

	dataDir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "valid-owner-password"); err != nil {
		t.Fatal(err)
	}
	adminToken, err := accounts.Login("owner", "valid-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	owner, ok := accounts.Identity(adminToken)
	if !ok {
		t.Fatal("admin session is not valid")
	}

	shared, err := files.NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer shared.Close()
	share, _ := shared.State()
	copyFixture := func(source, name string) string {
		t.Helper()
		data, err := os.ReadFile(source)
		if err != nil {
			t.Fatal(err)
		}
		destination := filepath.Join(share, name)
		if err := os.WriteFile(destination, data, 0600); err != nil {
			t.Fatal(err)
		}
		return destination
	}
	copyFixture(heicPath, "orientation.heic")
	// The bytes are a real MP4. Keeping a .mov name proves that the verified
	// container and MIME come from the bytes rather than the filename.
	copyFixture(mp4Path, "renamed.mp4.mov")

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
	worker := mediaworker.New(workerPath)
	photos.SetMediaWorker(worker)
	films.SetMediaWorker(worker)
	if err := photos.StartScan(); err != nil {
		t.Fatal(err)
	}
	if err := films.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitMediaLibraries(t, photos, films)

	assets, _, err := photos.List(0, 20, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	var photoID int64
	for _, asset := range assets {
		if asset.Name == "orientation.heic" {
			photoID = asset.ID
			if asset.ProbeStatus != "ready" || asset.Orientation != 6 || asset.Width != 80 || asset.Height != 48 || asset.CapturedAt == "" {
				t.Fatalf("HEIC worker metadata = %+v", asset)
			}
		}
	}
	if photoID == 0 {
		t.Fatal("HEIC photo was not indexed")
	}

	filmItems, _, err := films.List(owner.ID, "", "", 20, 0)
	if err != nil || len(filmItems) != 1 {
		t.Fatalf("renamed MP4 index = %+v, %v", filmItems, err)
	}
	film := filmItems[0]
	if film.ProbeStatus != "ready" || film.BrowserPlayback != "verified-direct" || film.Mime != "video/mp4" || film.Container != "MPEG-4" {
		t.Fatalf("renamed MP4 content classification = %+v", film)
	}

	handler := NewWithCinema("", accounts, shared, photos, films)
	call := func(path string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, path, nil)
		r.AddCookie(&http.Cookie{Name: sessionCookie, Value: adminToken})
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	photoResponse := call("/api/v1/photos/" + strconv.FormatInt(photoID, 10) + "/thumbnail")
	assertOrientedPhotoThumbnailResponse(t, photoResponse)
	originalFixture, err := os.ReadFile(heicPath)
	if err != nil {
		t.Fatal(err)
	}
	originalPhoto, err := os.ReadFile(filepath.Join(share, "orientation.heic"))
	if err != nil || !bytes.Equal(originalPhoto, originalFixture) {
		t.Fatalf("photo thumbnail generation changed the source: read=%v equal=%t", err, bytes.Equal(originalPhoto, originalFixture))
	}
	posterResponse := call("/api/v1/cinema/" + strconv.FormatInt(film.ID, 10) + "/poster")
	assertJPEGResponse(t, posterResponse, 96, 64)

	// The photos and cinema endpoints share one cache entry for this source.
	galleryVideos := []int64{}
	for _, asset := range assets {
		if asset.Type == "video" {
			galleryVideos = append(galleryVideos, asset.ID)
		}
	}
	if len(galleryVideos) != 1 {
		t.Fatalf("gallery did not index the renamed video: %+v", assets)
	}
	thumbnailResponse := call("/api/v1/photos/" + strconv.FormatInt(galleryVideos[0], 10) + "/thumbnail")
	assertJPEGResponse(t, thumbnailResponse, 96, 64)
}

func assertOrientedPhotoThumbnailResponse(t *testing.T, response *httptest.ResponseRecorder) {
	t.Helper()
	if response.Code != http.StatusOK || response.Header().Get("Content-Type") != "image/jpeg" {
		t.Fatalf("photo thumbnail response = %d %q %s", response.Code, response.Header().Get("Content-Type"), response.Body.String())
	}
	image, err := jpeg.DecodeConfig(response.Body)
	if err != nil {
		t.Fatalf("photo thumbnail is not a decodable JPEG: %v", err)
	}
	if image.Width >= image.Height || image.Width > 512 || image.Height > 512 {
		t.Fatalf("orientation-6 photo thumbnail dimensions = %dx%d", image.Width, image.Height)
	}
	if ratio := float64(image.Width) / float64(image.Height); ratio < 0.59 || ratio > 0.61 {
		t.Fatalf("orientation-6 photo thumbnail ratio = %.3f, want near 48/80", ratio)
	}
}

func assertJPEGResponse(t *testing.T, response *httptest.ResponseRecorder, width, height int) {
	t.Helper()
	if response.Code != http.StatusOK || response.Header().Get("Content-Type") != "image/jpeg" {
		t.Fatalf("media thumbnail response = %d %q %s", response.Code, response.Header().Get("Content-Type"), response.Body.String())
	}
	image, err := jpeg.DecodeConfig(response.Body)
	if err != nil {
		t.Fatalf("response is not a decodable JPEG: %v", err)
	}
	if (width > 0 && image.Width != width) || (height > 0 && image.Height != height) {
		t.Fatalf("JPEG dimensions = %dx%d, want %dx%d", image.Width, image.Height, width, height)
	}
}
