// Package mediaworker runs the bundled, trusted macOS media helper. It passes
// already-open source files as fd 3 and never asks the helper to reopen a share
// path by name.
package mediaworker

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image/jpeg"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	ProtocolVersion   = 1
	MaxResponseBytes  = 32 << 10
	MaxStderrBytes    = 4 << 10
	MaxThumbnailBytes = 8 << 20
	MaxPreviewBytes   = 12 << 20
	defaultTimeout    = 20 * time.Second
	defaultParallel   = 2
)

var (
	ErrUnavailable     = errors.New("media_worker_unavailable")
	ErrInvalidResponse = errors.New("media_worker_invalid_response")
	ErrOutputTooLarge  = errors.New("media_worker_output_too_large")
	ErrUnsupported     = errors.New("media_unsupported")
)

type Metadata struct {
	Version         int     `json:"version"`
	Status          string  `json:"status"`
	Kind            string  `json:"kind,omitempty"`
	MIME            string  `json:"mime,omitempty"`
	Container       string  `json:"container,omitempty"`
	VideoCodec      string  `json:"videoCodec,omitempty"`
	AudioCodec      string  `json:"audioCodec,omitempty"`
	DurationSeconds float64 `json:"durationSeconds,omitempty"`
	Width           int     `json:"width,omitempty"`
	Height          int     `json:"height,omitempty"`
	Orientation     int     `json:"orientation,omitempty"`
	CapturedAt      string  `json:"capturedAt,omitempty"`
	// Capture location and camera metadata. Zero values mean "absent"; the
	// worker itself drops the null-island (0,0) coordinate.
	Latitude        float64 `json:"latitude,omitempty"`
	Longitude       float64 `json:"longitude,omitempty"`
	CameraMake      string  `json:"cameraMake,omitempty"`
	CameraModel     string  `json:"cameraModel,omitempty"`
	LensModel       string  `json:"lensModel,omitempty"`
	ISO             int     `json:"iso,omitempty"`
	FNumber         float64 `json:"fNumber,omitempty"`
	ExposureSeconds float64 `json:"exposureSeconds,omitempty"`
	FocalLength     float64 `json:"focalLength,omitempty"`
	Error           string  `json:"error,omitempty"`
}

type Client struct {
	path       string
	timeout    time.Duration
	slots      chan struct{}
	mu         sync.Mutex
	lastStderr string
}

// New uses an explicit executable path when provided. With an empty path it
// looks only beside the running core binary, which is where the app bundle
// places Contents/Resources/core/lightisle-media-worker.
func New(explicitPath string) *Client {
	path := explicitPath
	if path == "" {
		if executable, err := os.Executable(); err == nil {
			path = filepath.Join(filepath.Dir(executable), "lightisle-media-worker")
		}
	}
	return &Client{path: filepath.Clean(path), timeout: defaultTimeout, slots: make(chan struct{}, defaultParallel)}
}

func (c *Client) Path() string { return c.path }

func (c *Client) Probe(ctx context.Context, source *os.File, name string) (Metadata, error) {
	return c.run(ctx, "probe", source, name, "")
}

func (c *Client) Poster(ctx context.Context, source *os.File, name, output string) (Metadata, error) {
	if !filepath.IsAbs(output) {
		return Metadata{}, errors.New("media_worker_output_path_must_be_absolute")
	}
	return c.run(ctx, "poster", source, name, filepath.Clean(output))
}

// Thumbnail asks the trusted native worker to make an orientation-correct
// 512-pixel JPEG. The worker claims the output path exclusively with mode
// 0600; this method validates its result before the gallery caches it.
func (c *Client) Thumbnail(ctx context.Context, source *os.File, name, output string) (Metadata, error) {
	if !filepath.IsAbs(output) {
		return Metadata{}, errors.New("media_worker_output_path_must_be_absolute")
	}
	output = filepath.Clean(output)
	extension := strings.ToLower(filepath.Ext(output))
	if extension != ".jpg" && extension != ".jpeg" {
		return Metadata{}, errors.New("media_worker_thumbnail_output_must_be_jpeg")
	}
	if _, err := os.Lstat(output); err == nil {
		return Metadata{}, errors.New("media_worker_thumbnail_output_already_exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return Metadata{}, err
	}
	metadata, err := c.run(ctx, "thumbnail", source, name, output)
	if err != nil {
		// A canceled process can be killed before its own cleanup runs. The
		// output path was confirmed absent above, and the worker claims it with
		// O_EXCL, so remove any partial result it left behind.
		_ = os.Remove(output)
		return Metadata{}, err
	}
	if err := validateThumbnailOutput(output); err != nil {
		_ = os.Remove(output)
		if errors.Is(err, ErrOutputTooLarge) {
			return Metadata{}, err
		}
		return Metadata{}, fmt.Errorf("%w: %v", ErrInvalidResponse, err)
	}
	return metadata, nil
}

// ThumbnailSized requests a JPEG of at most maxPixel on the long edge. Only
// the two sizes the server actually serves are accepted, matching the
// worker's own whitelist; everything else fails validation before spawn.
func (c *Client) ThumbnailSized(ctx context.Context, source *os.File, name, output string, maxPixel int) (Metadata, error) {
	if maxPixel != 512 && maxPixel != 2048 {
		return Metadata{}, ErrInvalidResponse
	}
	if !filepath.IsAbs(output) {
		return Metadata{}, errors.New("media_worker_output_path_must_be_absolute")
	}
	output = filepath.Clean(output)
	extension := strings.ToLower(filepath.Ext(output))
	if extension != ".jpg" && extension != ".jpeg" {
		return Metadata{}, ErrInvalidResponse
	}
	if _, err := os.Lstat(output); err == nil {
		return Metadata{}, errors.New("media_worker_thumbnail_output_already_exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return Metadata{}, err
	}
	metadata, err := c.run(ctx, "thumbnail", source, name, output, "--max-pixel", strconv.Itoa(maxPixel))
	if err != nil {
		_ = os.Remove(output)
		return Metadata{}, err
	}
	if err := validateSizedJPEGOutput(output, maxPixel); err != nil {
		_ = os.Remove(output)
		if errors.Is(err, ErrOutputTooLarge) {
			return Metadata{}, err
		}
		return Metadata{}, fmt.Errorf("%w: %v", ErrInvalidResponse, err)
	}
	return metadata, nil
}

func (c *Client) run(parent context.Context, operation string, source *os.File, name, output string, extraArgs ...string) (Metadata, error) {
	if operation != "probe" && operation != "poster" && operation != "thumbnail" || source == nil || !validName(name) {
		return Metadata{}, ErrInvalidResponse
	}
	if operation != "probe" && output == "" {
		return Metadata{}, ErrInvalidResponse
	}
	if parent == nil {
		parent = context.Background()
	}
	if !filepath.IsAbs(c.path) {
		return Metadata{}, fmt.Errorf("%w: executable path must be absolute", ErrUnavailable)
	}
	info, err := os.Lstat(c.path)
	if err != nil {
		return Metadata{}, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	if !info.Mode().IsRegular() || info.Mode()&0111 == 0 {
		return Metadata{}, fmt.Errorf("%w: trusted executable is not a regular executable", ErrUnavailable)
	}
	stat, err := source.Stat()
	if err != nil || !stat.Mode().IsRegular() {
		return Metadata{}, errors.New("media_worker_source_must_be_regular_file")
	}
	select {
	case c.slots <- struct{}{}:
		defer func() { <-c.slots }()
	case <-parent.Done():
		return Metadata{}, parent.Err()
	}

	ctx, cancel := context.WithTimeout(parent, c.timeout)
	defer cancel()
	args := []string{operation, "--input-fd", "3", "--name", filepath.Base(name)}
	if operation == "poster" || operation == "thumbnail" {
		args = append(args, "--output", output)
	}
	args = append(args, extraArgs...)
	cmd := exec.CommandContext(ctx, c.path, args...)
	cmd.ExtraFiles = []*os.File{source}
	stdout := &boundedWriter{limit: MaxResponseBytes}
	stderr := &boundedWriter{limit: MaxStderrBytes}
	cmd.Stdout, cmd.Stderr = stdout, stderr
	runErr := cmd.Run()
	c.mu.Lock()
	c.lastStderr = stderr.String()
	c.mu.Unlock()
	if ctx.Err() != nil {
		return Metadata{}, ctx.Err()
	}
	if stdout.overflowed() {
		return Metadata{}, ErrOutputTooLarge
	}
	metadata, decodeErr := decodeResponse(stdout.Bytes())
	if decodeErr != nil {
		if runErr != nil {
			return Metadata{}, fmt.Errorf("%w: %v", ErrInvalidResponse, runErr)
		}
		return Metadata{}, decodeErr
	}
	switch metadata.Status {
	case "ok":
		if runErr != nil || !validMetadata(metadata, operation) {
			return Metadata{}, fmt.Errorf("%w: invalid successful result", ErrInvalidResponse)
		}
		return metadata, nil
	case "unsupported":
		if runErr != nil {
			return Metadata{}, fmt.Errorf("%w: unsupported result exited nonzero", ErrInvalidResponse)
		}
		return metadata, ErrUnsupported
	case "error":
		if runErr == nil {
			return Metadata{}, fmt.Errorf("%w: error result exited successfully", ErrInvalidResponse)
		}
		if metadata.Error == "" {
			metadata.Error = "media_worker_failed"
		}
		return Metadata{}, errors.New(metadata.Error)
	default:
		return Metadata{}, ErrInvalidResponse
	}
}

func (c *Client) LastStderr() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.lastStderr
}

func validName(name string) bool {
	base := filepath.Base(name)
	return name != "" && base == name && !strings.ContainsAny(name, "/\\\x00")
}

func validMetadata(m Metadata, operation string) bool {
	if m.Version != ProtocolVersion || m.Status != "ok" || (m.Kind != "video" && m.Kind != "photo") {
		return false
	}
	if m.Width < 1 || m.Width > 32768 || m.Height < 1 || m.Height > 32768 {
		return false
	}
	if m.Orientation < 0 || m.Orientation > 8 {
		return false
	}
	if operation == "probe" && m.Kind == "video" {
		if m.DurationSeconds <= 0 || m.DurationSeconds > 86400*30 {
			return false
		}
	}
	if operation == "poster" && m.Kind != "video" {
		return false
	}
	if operation == "thumbnail" && m.Kind != "photo" {
		return false
	}
	if m.DurationSeconds < 0 || m.DurationSeconds > 86400*30 {
		return false
	}
	if m.CapturedAt != "" {
		if _, err := time.Parse(time.RFC3339Nano, m.CapturedAt); err != nil {
			return false
		}
	}
	if !validCaptureMetadata(m) {
		return false
	}
	return true
}

// validCaptureMetadata keeps fabricated worker output (or a corrupted EXIF
// payload) from seeding the map view with impossible coordinates and camera
// values. Absent fields are zero and stay allowed.
func validCaptureMetadata(m Metadata) bool {
	if m.Latitude != 0 || m.Longitude != 0 {
		if m.Latitude < -90 || m.Latitude > 90 || m.Longitude < -180 || m.Longitude > 180 {
			return false
		}
	}
	if m.ISO < 0 || m.ISO > 1<<20 || m.FNumber < 0 || m.FNumber > 1000 {
		return false
	}
	if m.ExposureSeconds < 0 || m.ExposureSeconds > 3600 || m.FocalLength < 0 || m.FocalLength > 2000 {
		return false
	}
	if len(m.CameraMake) > 64 || len(m.CameraModel) > 128 || len(m.LensModel) > 128 {
		return false
	}
	return true
}

func validateThumbnailOutput(path string) error {
	return validateSizedJPEGOutput(path, 512)
}

// validateSizedJPEGOutput checks the worker's O_EXCL JPEG against the
// requested long-edge budget. A 2048px preview may legitimately be larger
// than a 512px thumbnail, so the byte cap scales with the requested size.
func validateSizedJPEGOutput(path string, maxPixel int) error {
	byteCap := int64(MaxThumbnailBytes)
	if maxPixel > 512 {
		byteCap = MaxPreviewBytes
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0600 || info.Size() < 5 {
		return errors.New("thumbnail_output_invalid")
	}
	if info.Size() > byteCap {
		return ErrOutputTooLarge
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	configuration, err := jpeg.DecodeConfig(io.LimitReader(file, byteCap+1))
	if err != nil || configuration.Width < 1 || configuration.Height < 1 ||
		configuration.Width > maxPixel || configuration.Height > maxPixel {
		return errors.New("thumbnail_output_invalid")
	}
	var footer [2]byte
	if _, err := file.ReadAt(footer[:], info.Size()-2); err != nil || footer != [2]byte{0xff, 0xd9} {
		return errors.New("thumbnail_output_invalid")
	}
	return nil
}

// BrowserPlayback classifies progressive playback conservatively. Only a
// successful worker probe plus a browser-supported container/codec pair is
// verified. The extension-only path is deliberately labeled as an attempt.
func BrowserPlayback(name string, metadata Metadata, verified bool) string {
	if !verified {
		ext := strings.ToLower(filepath.Ext(name))
		switch ext {
		case ".mp4", ".m4v", ".webm":
			return "unverified-direct"
		default:
			return "download-only"
		}
	}
	if metadata.Status != "ok" || metadata.Kind != "video" {
		return "download-only"
	}
	container := strings.ToLower(strings.TrimSpace(metadata.Container))
	videoCodec := strings.ToLower(strings.TrimSpace(metadata.VideoCodec))
	audioCodec := strings.ToLower(strings.TrimSpace(metadata.AudioCodec))
	switch container {
	case "mp4", "mpeg-4", "mpeg4", "m4v":
		if (videoCodec == "h264" || videoCodec == "avc" || strings.HasPrefix(videoCodec, "avc1")) &&
			(audioCodec == "" || audioCodec == "aac" || strings.HasPrefix(audioCodec, "mp4a") || audioCodec == "mp3") {
			return "verified-direct"
		}
	case "webm":
		vp8 := videoCodec == "vp8" || strings.HasPrefix(videoCodec, "vp08")
		vp9 := videoCodec == "vp9" || strings.HasPrefix(videoCodec, "vp09")
		audioOK := audioCodec == "" || audioCodec == "opus" || audioCodec == "vorbis"
		if (vp8 || vp9) && audioOK {
			return "verified-direct"
		}
	}
	return "download-only"
}

func decodeResponse(data []byte) (Metadata, error) {
	if len(data) == 0 || len(data) > MaxResponseBytes || bytes.Count(data, []byte("\n")) > 1 {
		return Metadata{}, ErrInvalidResponse
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var metadata Metadata
	if err := decoder.Decode(&metadata); err != nil {
		return Metadata{}, fmt.Errorf("%w: %v", ErrInvalidResponse, err)
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return Metadata{}, ErrInvalidResponse
	}
	if metadata.Version != ProtocolVersion {
		return Metadata{}, ErrInvalidResponse
	}
	return metadata, nil
}

// boundedWriter always drains child output while retaining at most limit bytes.
// It reports overflow after Run so the worker cannot block on a full pipe.
type boundedWriter struct {
	mu       sync.Mutex
	limit    int
	data     bytes.Buffer
	overflow bool
}

func (w *boundedWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	remaining := w.limit - w.data.Len()
	if remaining > 0 {
		keep := len(p)
		if keep > remaining {
			keep = remaining
		}
		_, _ = w.data.Write(p[:keep])
	}
	if len(p) > remaining {
		w.overflow = true
	}
	return len(p), nil
}

func (w *boundedWriter) Bytes() []byte {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]byte(nil), w.data.Bytes()...)
}

func (w *boundedWriter) String() string { return string(w.Bytes()) }

func (w *boundedWriter) overflowed() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.overflow
}
