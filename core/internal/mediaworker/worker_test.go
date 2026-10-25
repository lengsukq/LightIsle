package mediaworker

import (
	"context"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The test binary doubles as a local fake worker. Production code never uses
// this path; the client still exercises exec, fd 3 inheritance, cancellation,
// and bounded protocol parsing without an external executable or dependency.
func init() {
	if os.Getenv("LIGHTISLE_TEST_MEDIA_WORKER") != "1" {
		return
	}
	os.Exit(runTestWorker())
}

func runTestWorker() int {
	mode := os.Getenv("LIGHTISLE_TEST_MEDIA_WORKER_MODE")
	if mode == "sleep" {
		time.Sleep(5 * time.Second)
		return 0
	}
	if mode == "oversized" {
		_, _ = io.WriteString(os.Stdout, strings.Repeat("x", MaxResponseBytes+1))
		return 0
	}
	if mode == "bad-json" {
		_, _ = io.WriteString(os.Stdout, "{broken\n")
		return 0
	}
	if mode == "unknown-field" {
		_, _ = io.WriteString(os.Stdout, `{"version":1,"status":"unsupported","unexpected":true}`+"\n")
		return 0
	}
	if mode == "unsupported" {
		_ = json.NewEncoder(os.Stdout).Encode(Metadata{Version: 1, Status: "unsupported"})
		return 0
	}
	if mode == "error" {
		_ = json.NewEncoder(os.Stdout).Encode(Metadata{Version: 1, Status: "error", Error: "fixture_decode_failed"})
		return 1
	}

	if len(os.Args) < 2 {
		return 2
	}
	source := os.NewFile(3, "fd3-source")
	if source == nil {
		return 2
	}
	data, err := io.ReadAll(io.LimitReader(source, 1<<20))
	_ = source.Close()
	if err != nil || string(data) != "source-data" {
		return 2
	}
	operation := os.Args[1]
	if operation == "poster" {
		output := ""
		for i := 2; i+1 < len(os.Args); i++ {
			if os.Args[i] == "--output" {
				output = os.Args[i+1]
				break
			}
		}
		if output == "" || os.WriteFile(output, []byte{0xFF, 0xD8, 0xFF, 1, 0xFF, 0xD9}, 0600) != nil {
			return 1
		}
	}
	if operation == "thumbnail" {
		output := ""
		for i := 2; i+1 < len(os.Args); i++ {
			if os.Args[i] == "--output" {
				output = os.Args[i+1]
				break
			}
		}
		if output == "" {
			return 1
		}
		if mode == "thumbnail-sleep" {
			if err := os.WriteFile(output, []byte("partial"), 0600); err != nil {
				return 1
			}
			time.Sleep(5 * time.Second)
			return 0
		}
		file, err := os.OpenFile(output, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return 1
		}
		fixture := image.NewRGBA(image.Rect(0, 0, 48, 80))
		for y := 0; y < 80; y++ {
			for x := 0; x < 48; x++ {
				fixture.Set(x, y, color.RGBA{R: 40, G: 120, B: 200, A: 255})
			}
		}
		encodeErr := jpeg.Encode(file, fixture, nil)
		closeErr := file.Close()
		if encodeErr != nil || closeErr != nil {
			return 1
		}
	}
	kind, width, height, orientation := "video", 80, 48, 0
	if operation == "thumbnail" {
		kind, width, height, orientation = "photo", 80, 48, 6
	}
	result := Metadata{
		Version: 1, Status: "ok", Kind: kind, MIME: "video/mp4", Container: "mp4",
		VideoCodec: "h264", AudioCodec: "aac", DurationSeconds: 2, Width: width, Height: height, Orientation: orientation,
	}
	_ = json.NewEncoder(os.Stdout).Encode(result)
	return 0
}

func newTestClient(t *testing.T, mode string) *Client {
	t.Helper()
	t.Setenv("LIGHTISLE_TEST_MEDIA_WORKER", "1")
	t.Setenv("LIGHTISLE_TEST_MEDIA_WORKER_MODE", mode)
	return New(os.Args[0])
}

func testSource(t *testing.T) *os.File {
	t.Helper()
	file, err := os.CreateTemp(t.TempDir(), "source-")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("source-data"); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		file.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = file.Close() })
	return file
}

func TestProbePassesOpenedSourceOnFD3(t *testing.T) {
	client := newTestClient(t, "")
	source := testSource(t)
	name := source.Name()
	if err := os.Remove(name); err != nil {
		t.Fatal(err)
	}
	metadata, err := client.Probe(context.Background(), source, "sample.mp4")
	if err != nil {
		t.Fatal(err)
	}
	if metadata.Status != "ok" || metadata.Kind != "video" || metadata.Width != 80 || metadata.DurationSeconds != 2 {
		t.Fatalf("unexpected probe metadata: %+v", metadata)
	}
}

func TestPosterWritesToPrivateOutput(t *testing.T) {
	client := newTestClient(t, "")
	source := testSource(t)
	output := filepath.Join(t.TempDir(), "poster.jpg")
	if _, err := os.Create(output); err != nil {
		t.Fatal(err)
	}
	metadata, err := client.Poster(context.Background(), source, "sample.mp4", output)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(output)
	if err != nil || len(data) < 5 || data[0] != 0xff || data[1] != 0xd8 {
		t.Fatalf("poster output invalid: %x, %v", data, err)
	}
	if metadata.Kind != "video" {
		t.Fatalf("unexpected poster metadata: %+v", metadata)
	}
}

func TestThumbnailWritesOrientedPrivateJPEG(t *testing.T) {
	client := newTestClient(t, "")
	source := testSource(t)
	output := filepath.Join(t.TempDir(), "thumbnail.jpg")
	metadata, err := client.Thumbnail(context.Background(), source, "orientation.heic", output)
	if err != nil {
		t.Fatal(err)
	}
	if metadata.Kind != "photo" || metadata.Orientation != 6 {
		t.Fatalf("unexpected thumbnail metadata: %+v", metadata)
	}
	file, err := os.Open(output)
	if err != nil {
		t.Fatal(err)
	}
	configuration, decodeErr := jpeg.DecodeConfig(file)
	closeErr := file.Close()
	if decodeErr != nil || closeErr != nil {
		t.Fatalf("thumbnail JPEG invalid: decode=%v close=%v", decodeErr, closeErr)
	}
	if configuration.Width != 48 || configuration.Height != 80 {
		t.Fatalf("thumbnail dimensions = %dx%d, want oriented 48x80", configuration.Width, configuration.Height)
	}
	info, err := os.Stat(output)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("thumbnail permissions = %v, %v; want 0600", info, err)
	}
}

func TestThumbnailRejectsExistingOutputWithoutOverwriting(t *testing.T) {
	client := newTestClient(t, "")
	source := testSource(t)
	output := filepath.Join(t.TempDir(), "thumbnail.jpg")
	if err := os.WriteFile(output, []byte("keep-existing"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Thumbnail(context.Background(), source, "orientation.heic", output); err == nil {
		t.Fatal("existing output was unexpectedly replaced")
	}
	data, err := os.ReadFile(output)
	if err != nil || string(data) != "keep-existing" {
		t.Fatalf("existing output changed: %q, %v", data, err)
	}
}

func TestCancelledThumbnailRemovesPartialOutput(t *testing.T) {
	client := newTestClient(t, "thumbnail-sleep")
	source := testSource(t)
	output := filepath.Join(t.TempDir(), "thumbnail.jpg")
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Millisecond)
	defer cancel()
	if _, err := client.Thumbnail(ctx, source, "orientation.heic", output); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("canceled thumbnail error = %v", err)
	}
	if _, err := os.Lstat(output); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("partial thumbnail survived cancellation: %v", err)
	}
}

func TestThumbnailOutputEnforcesByteLimit(t *testing.T) {
	output := filepath.Join(t.TempDir(), "oversized.jpg")
	file, err := os.OpenFile(output, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(MaxThumbnailBytes + 1); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if err := validateThumbnailOutput(output); !errors.Is(err, ErrOutputTooLarge) {
		t.Fatalf("oversized thumbnail error = %v", err)
	}
}

func TestUnsupportedAndInvalidWorkerResponses(t *testing.T) {
	for _, test := range []struct {
		mode string
		want error
	}{
		{mode: "unsupported", want: ErrUnsupported},
		{mode: "bad-json", want: ErrInvalidResponse},
		{mode: "unknown-field", want: ErrInvalidResponse},
		{mode: "oversized", want: ErrOutputTooLarge},
		{mode: "error", want: errors.New("fixture_decode_failed")},
	} {
		t.Run(test.mode, func(t *testing.T) {
			client := newTestClient(t, test.mode)
			_, err := client.Probe(context.Background(), testSource(t), "unknown.ext")
			if err == nil || (test.want == ErrUnsupported || test.want == ErrInvalidResponse || test.want == ErrOutputTooLarge) && !errors.Is(err, test.want) {
				t.Fatalf("error = %v, want %v", err, test.want)
			}
			if test.mode == "error" && !strings.Contains(err.Error(), "fixture_decode_failed") {
				t.Fatalf("worker diagnostic lost: %v", err)
			}
		})
	}
}

func TestCancelledWorkerProcessStops(t *testing.T) {
	client := newTestClient(t, "sleep")
	source := testSource(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Millisecond)
	defer cancel()
	started := time.Now()
	_, err := client.Probe(ctx, source, "sample.mp4")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("canceled worker error = %v", err)
	}
	if time.Since(started) > time.Second {
		t.Fatalf("worker process did not stop promptly: %s", time.Since(started))
	}
}

func TestRejectsRelativeExecutableAndUnsafeName(t *testing.T) {
	client := New("worker")
	if _, err := client.Probe(context.Background(), testSource(t), "sample.mp4"); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("relative worker path error = %v", err)
	}
	client = newTestClient(t, "")
	if _, err := client.Probe(context.Background(), testSource(t), "../sample.mp4"); err == nil {
		t.Fatal("unsafe worker name accepted")
	}
}

func TestBrowserPlaybackUsesConservativeProbeMatrix(t *testing.T) {
	cases := []struct {
		name     string
		metadata Metadata
		verified bool
		want     string
	}{
		{"movie.mp4", Metadata{Status: "ok", Kind: "video", Container: "mp4", VideoCodec: "h264", AudioCodec: "aac"}, true, "verified-direct"},
		{"movie.m4v", Metadata{Status: "ok", Kind: "video", Container: "m4v", VideoCodec: "avc1.640028", AudioCodec: "mp4a.40.2"}, true, "verified-direct"},
		{"movie.mp4", Metadata{Status: "ok", Kind: "video", Container: "mp4", VideoCodec: "hevc", AudioCodec: "aac"}, true, "download-only"},
		{"movie.webm", Metadata{Status: "ok", Kind: "video", Container: "webm", VideoCodec: "vp09.00.10.08", AudioCodec: "opus"}, true, "verified-direct"},
		{"movie.mov", Metadata{Status: "ok", Kind: "video", Container: "quicktime", VideoCodec: "h264", AudioCodec: "aac"}, true, "download-only"},
		{"movie.mp4", Metadata{}, false, "unverified-direct"},
		{"movie.mkv", Metadata{}, false, "download-only"},
	}
	for _, test := range cases {
		if got := BrowserPlayback(test.name, test.metadata, test.verified); got != test.want {
			t.Errorf("BrowserPlayback(%s) = %q, want %q", test.name, got, test.want)
		}
	}
}

func TestValidCaptureMetadataMatrix(t *testing.T) {
	base := func() Metadata {
		return Metadata{Version: 1, Status: "ok", Kind: "photo", Width: 8, Height: 6,
			Latitude: 31.2304, Longitude: 121.4737,
			CameraMake: "Apple", CameraModel: "iPhone 17 Pro", LensModel: "Main 24mm",
			ISO: 125, FNumber: 1.78, ExposureSeconds: 0.01, FocalLength: 24}
	}
	valid := []Metadata{base()}
	invalid := []struct {
		name   string
		mutate func(*Metadata)
	}{
		{"south pole latitude", func(m *Metadata) { m.Latitude = -91 }},
		{"excess latitude", func(m *Metadata) { m.Latitude = 91 }},
		{"excess longitude", func(m *Metadata) { m.Longitude = 181 }},
		{"huge iso", func(m *Metadata) { m.ISO = 1 << 21 }},
		{"huge f-number", func(m *Metadata) { m.FNumber = 1001 }},
		{"negative exposure", func(m *Metadata) { m.ExposureSeconds = -0.1 }},
		{"hour-long exposure", func(m *Metadata) { m.ExposureSeconds = 3601 }},
		{"huge focal length", func(m *Metadata) { m.FocalLength = 2001 }},
		{"oversized camera make", func(m *Metadata) { m.CameraMake = strings.Repeat("x", 65) }},
		{"oversized lens model", func(m *Metadata) { m.LensModel = strings.Repeat("x", 129) }},
	}
	for _, test := range invalid {
		metadata := base()
		test.mutate(&metadata)
		if validMetadata(metadata, "probe") {
			t.Errorf("validMetadata accepted %s metadata", test.name)
		}
	}
	for _, metadata := range valid {
		if !validMetadata(metadata, "probe") {
			t.Errorf("validMetadata rejected legitimate capture metadata %+v", metadata)
		}
	}
	absent := Metadata{Version: 1, Status: "ok", Kind: "photo", Width: 8, Height: 6}
	if !validMetadata(absent, "probe") {
		t.Error("validMetadata rejected metadata without capture fields")
	}
}
