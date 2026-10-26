package gallery

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
	_ "github.com/mattn/go-sqlite3"
)

type fakeMediaWorker struct {
	mu          sync.Mutex
	probe       func(context.Context, *os.File, string) (mediaworker.Metadata, error)
	poster      func(context.Context, *os.File, string, string) (mediaworker.Metadata, error)
	probeCalls  map[string]int
	posterCalls int
}

func (w *fakeMediaWorker) Probe(ctx context.Context, source *os.File, name string) (mediaworker.Metadata, error) {
	w.mu.Lock()
	if w.probeCalls == nil {
		w.probeCalls = map[string]int{}
	}
	w.probeCalls[name]++
	fn := w.probe
	w.mu.Unlock()
	if fn == nil {
		return mediaworker.Metadata{}, errors.New("missing_fake_probe")
	}
	return fn(ctx, source, name)
}

func (w *fakeMediaWorker) Poster(ctx context.Context, source *os.File, name, output string) (mediaworker.Metadata, error) {
	w.mu.Lock()
	w.posterCalls++
	fn := w.poster
	w.mu.Unlock()
	if fn == nil {
		return mediaworker.Metadata{}, errors.New("missing_fake_poster")
	}
	return fn(ctx, source, name, output)
}

func (w *fakeMediaWorker) calls(name string) int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.probeCalls[name]
}

func (w *fakeMediaWorker) posterCount() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.posterCalls
}

func scanGallery(t *testing.T, library *Library) {
	t.Helper()
	if err := library.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for library.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if status := library.Status(); status.Running || status.LastError != "" {
		t.Fatalf("gallery scan did not finish: %+v", status)
	}
}

func assetByName(t *testing.T, library *Library, name string) Asset {
	t.Helper()
	assets, _, err := library.List(0, 120, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	for _, asset := range assets {
		if asset.Name == name {
			return asset
		}
	}
	t.Fatalf("asset %q missing", name)
	return Asset{}
}

func TestProbeMetadataRetriesFailuresAndPreservesRealHistory(t *testing.T) {
	env := newTestLibrary(t, []byte("unused"))
	modified := time.Unix(1_700_000_000, 0)
	writeTestPhoto(t, env.root, "camera.heic", "heic-bytes", modified)
	writeTestPhoto(t, env.root, "clip.mp4", "video-bytes", modified)

	worker := &fakeMediaWorker{}
	worker.probe = func(_ context.Context, _ *os.File, name string) (mediaworker.Metadata, error) {
		if name == "camera.heic" {
			return mediaworker.Metadata{Version: 1, Status: "ok", Kind: "photo", MIME: "image/heic", Width: 80, Height: 48,
				Orientation: 6, CapturedAt: "2024-03-04T05:06:07+08:00"}, nil
		}
		if worker.calls(name) == 1 {
			return mediaworker.Metadata{}, errors.New("first decode failed")
		}
		return mediaworker.Metadata{Version: 1, Status: "ok", Kind: "video", MIME: "video/mp4", Container: "mp4",
			VideoCodec: "h264", AudioCodec: "aac", DurationSeconds: 4.25, Width: 1280, Height: 720}, nil
	}
	env.library.SetMediaWorker(worker)
	scanGallery(t, env.library)

	photo := assetByName(t, env.library, "camera.heic")
	if photo.ProbeStatus != "ready" || photo.Width != 80 || photo.Height != 48 || photo.Orientation != 6 || photo.CapturedAt != "2024-03-04T05:06:07+08:00" {
		t.Fatalf("HEIC metadata not persisted: %+v", photo)
	}
	captured, _ := time.Parse(time.RFC3339Nano, photo.CapturedAt)
	if photo.TakenAt != captured.Unix() {
		t.Fatalf("TakenAt %d did not use worker capture time %d", photo.TakenAt, captured.Unix())
	}
	clip := assetByName(t, env.library, "clip.mp4")
	if clip.ProbeStatus != "failed" || clip.BrowserPlayback != "download-only" || clip.DurationSeconds != 0 {
		t.Fatalf("failed probe was presented as ready/playable: %+v", clip)
	}

	scanGallery(t, env.library)
	clip = assetByName(t, env.library, "clip.mp4")
	if clip.ProbeStatus != "ready" || clip.BrowserPlayback != "verified-direct" || clip.DurationSeconds != 4.25 || clip.VideoCodec != "h264" {
		t.Fatalf("retry did not persist verified metadata: %+v", clip)
	}
	if worker.calls("camera.heic") != 1 || worker.calls("clip.mp4") != 2 {
		t.Fatalf("unexpected unchanged/retry probe counts: photo=%d video=%d", worker.calls("camera.heic"), worker.calls("clip.mp4"))
	}

	clipPath := filepath.Join(env.root, "SharedFiles", "clip.mp4")
	if err := os.WriteFile(clipPath, []byte("changed-video-bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	changed := modified.Add(time.Minute)
	if err := os.Chtimes(clipPath, changed, changed); err != nil {
		t.Fatal(err)
	}
	scanGallery(t, env.library)
	if worker.calls("clip.mp4") != 3 {
		t.Fatalf("source change did not trigger re-probe: %d", worker.calls("clip.mp4"))
	}
}

func TestGalleryVideoPosterUsesSharedCacheAndRejectsChangedSource(t *testing.T) {
	env := newTestLibrary(t, nil)
	writeTestPhoto(t, env.root, "clip.mp4", "some-video-bytes", time.Unix(1_700_000_100, 0))
	worker := &fakeMediaWorker{}
	worker.probe = func(context.Context, *os.File, string) (mediaworker.Metadata, error) {
		return mediaworker.Metadata{Version: 1, Status: "ok", Kind: "video", Container: "mp4", VideoCodec: "h264", AudioCodec: "aac", DurationSeconds: 2, Width: 80, Height: 48}, nil
	}
	worker.poster = func(_ context.Context, _ *os.File, _ string, output string) (mediaworker.Metadata, error) {
		if err := os.WriteFile(output, jpegEnvelope([]byte("poster")), 0600); err != nil {
			return mediaworker.Metadata{}, err
		}
		return mediaworker.Metadata{Version: 1, Status: "ok", Kind: "video", Width: 80, Height: 48}, nil
	}
	env.library.SetMediaWorker(worker)
	scanGallery(t, env.library)
	asset := assetByName(t, env.library, "clip.mp4")
	for i := 0; i < 2; i++ {
		poster, err := env.library.VideoThumbnail(asset.ID)
		if err != nil {
			t.Fatal(err)
		}
		poster.Close()
	}
	if worker.posterCount() != 1 {
		t.Fatalf("shared cache rendered %d times", worker.posterCount())
	}

	path := filepath.Join(env.root, "SharedFiles", "clip.mp4")
	if err := os.WriteFile(path, []byte("a larger changed video"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := env.library.VideoThumbnail(asset.ID); !errors.Is(err, ErrAssetChanged) {
		t.Fatalf("stale index returned poster: %v", err)
	}
}

func TestGalleryVideoPosterHonorsCancellation(t *testing.T) {
	env := newTestLibrary(t, nil)
	writeTestPhoto(t, env.root, "clip.mp4", "video", time.Unix(1_700_000_200, 0))
	started := make(chan struct{})
	worker := &fakeMediaWorker{poster: func(ctx context.Context, _ *os.File, _ string, _ string) (mediaworker.Metadata, error) {
		close(started)
		<-ctx.Done()
		return mediaworker.Metadata{}, ctx.Err()
	}}
	env.library.SetMediaWorker(worker)
	scanGallery(t, env.library)
	asset := assetByName(t, env.library, "clip.mp4")
	requestCtx, cancelRequest := context.WithCancel(context.Background())
	defer cancelRequest()
	finished := make(chan error, 1)
	go func() { _, err := env.library.VideoThumbnailContext(requestCtx, asset.ID); finished <- err }()
	<-started
	cancelRequest()
	select {
	case err := <-finished:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("canceled poster error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("poster worker did not stop after library cancellation")
	}
}

func TestVideoFingerprintDetectsUnsampledEditAfterMtimeRestore(t *testing.T) {
	path := filepath.Join(t.TempDir(), "large.mp4")
	contents := make([]byte, 2<<20)
	for i := range contents {
		contents[i] = byte(i * 31)
	}
	if err := os.WriteFile(path, contents, 0600); err != nil {
		t.Fatal(err)
	}
	original := time.Unix(1_700_001_000, 0)
	if err := os.Chtimes(path, original, original); err != nil {
		t.Fatal(err)
	}
	file, err := os.OpenFile(path, os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	beforeInfo, _ := file.Stat()
	before, err := videoFingerprint(file, beforeInfo)
	if err != nil {
		t.Fatal(err)
	}
	// This quarter-file range is outside the three sampled byte windows.
	if _, err := file.WriteAt([]byte("changed-unsampled-range"), 512<<10); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, original, original); err != nil {
		t.Fatal(err)
	}
	afterInfo, _ := file.Stat()
	after, err := videoFingerprint(file, afterInfo)
	if err != nil {
		t.Fatal(err)
	}
	if before == after {
		t.Fatal("video source version ignored inode ctime after same-size edit with restored mtime")
	}
}

func TestVideoPosterRejectsSameMetadataPathReplacement(t *testing.T) {
	env := newTestLibrary(t, nil)
	modified := time.Unix(1_700_001_100, 0)
	writeTestPhoto(t, env.root, "clip.mp4", "original-content", modified)
	path := filepath.Join(env.root, "SharedFiles", "clip.mp4")
	replacement := filepath.Join(env.root, "SharedFiles", "replacement.tmp")
	if err := os.WriteFile(replacement, []byte("replaced--content"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(replacement, modified, modified); err != nil {
		t.Fatal(err)
	}
	worker := &fakeMediaWorker{}
	worker.poster = func(_ context.Context, _ *os.File, _ string, output string) (mediaworker.Metadata, error) {
		if err := os.Rename(replacement, path); err != nil {
			return mediaworker.Metadata{}, err
		}
		if err := os.Chtimes(path, modified, modified); err != nil {
			return mediaworker.Metadata{}, err
		}
		if err := os.WriteFile(output, jpegEnvelope([]byte("poster")), 0600); err != nil {
			return mediaworker.Metadata{}, err
		}
		return mediaworker.Metadata{Version: 1, Status: "ok", Kind: "video", Width: 80, Height: 48}, nil
	}
	env.library.SetMediaWorker(worker)
	old, info, err := env.storage.Read("clip.mp4")
	if err != nil {
		t.Fatal(err)
	}
	defer old.Close()
	if info.Size() != int64(len("original-content")) || info.ModTime().UnixNano() != modified.UnixNano() {
		t.Fatalf("unexpected source setup: %d %s", info.Size(), info.ModTime())
	}
	if _, err := env.library.VideoThumbnailFromFile("clip.mp4", old, info); !errors.Is(err, ErrAssetChanged) {
		t.Fatalf("same-size/mtime inode replacement was accepted: %v", err)
	}
}

func TestVideoPosterRejectsShareRootSwitchDuringWorker(t *testing.T) {
	env := newTestLibrary(t, nil)
	modified := time.Unix(1_700_001_200, 0)
	writeTestPhoto(t, env.root, "clip.mp4", "source-data", modified)
	newRoot, err := os.MkdirTemp(mustUserHome(t), ".lightisle-media-root-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = env.library.Close()
		_ = env.storage.Close()
		_ = os.RemoveAll(newRoot)
	})
	worker := &fakeMediaWorker{}
	worker.poster = func(_ context.Context, _ *os.File, _ string, output string) (mediaworker.Metadata, error) {
		if err := os.WriteFile(filepath.Join(newRoot, "clip.mp4"), []byte("replacement"), 0600); err != nil {
			return mediaworker.Metadata{}, err
		}
		if err := env.storage.SetRootWithLegacyTransition(newRoot, func() error { return nil }, func() error { return nil }); err != nil {
			return mediaworker.Metadata{}, err
		}
		if err := os.WriteFile(output, jpegEnvelope([]byte("poster")), 0600); err != nil {
			return mediaworker.Metadata{}, err
		}
		return mediaworker.Metadata{Version: 1, Status: "ok", Kind: "video", Width: 80, Height: 48}, nil
	}
	env.library.SetMediaWorker(worker)
	source, info, err := env.storage.Read("clip.mp4")
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	if _, err := env.library.VideoThumbnailFromFile("clip.mp4", source, info); !errors.Is(err, ErrAssetChanged) {
		t.Fatalf("root switch during worker was accepted: %v", err)
	}
}

func mustUserHome(t *testing.T) string {
	t.Helper()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	return home
}

func TestVideoPosterLockWaitHonorsRequestCancellation(t *testing.T) {
	env := newTestLibrary(t, nil)
	writeTestPhoto(t, env.root, "clip.mp4", "video", time.Unix(1_700_001_300, 0))
	worker := &fakeMediaWorker{}
	worker.poster = func(_ context.Context, _ *os.File, _ string, _ string) (mediaworker.Metadata, error) {
		t.Fatal("poster worker ran while the request was waiting for the cache gate")
		return mediaworker.Metadata{}, nil
	}
	env.library.SetMediaWorker(worker)
	scanGallery(t, env.library)
	asset := assetByName(t, env.library, "clip.mp4")
	if err := env.library.thumbMu.lock(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := env.library.VideoThumbnailContext(ctx, asset.ID); done <- err }()
	select {
	case err := <-done:
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("lock-wait error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("thumbnail request remained blocked after its context expired")
	}
	env.library.thumbMu.unlock()
}

func TestLegacyGallerySchemaGetsProbeColumnsWithoutInventedResults(t *testing.T) {
	root := t.TempDir()
	storage, err := files.NewManager(root)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	share, _ := storage.State()
	db, err := sql.Open("sqlite3", filepath.Join(root, "gallery.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE assets(id INTEGER PRIMARY KEY AUTOINCREMENT,share TEXT NOT NULL,path TEXT NOT NULL,type TEXT NOT NULL,size INTEGER NOT NULL,modified INTEGER NOT NULL,taken_at INTEGER NOT NULL,seen INTEGER NOT NULL DEFAULT 0,favorite INTEGER NOT NULL DEFAULT 0,UNIQUE(share,path)); INSERT INTO assets(share,path,type,size,modified,taken_at) VALUES(?,?,?,?,?,?)`, share, "old.mp4", "video", 10, 123, 456)
	if err != nil {
		db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	library, err := Open(root, storage)
	if err != nil {
		t.Fatal(err)
	}
	defer library.Close()
	asset, err := library.Asset(1)
	if err != nil {
		t.Fatal(err)
	}
	if asset.ProbeStatus != "" || asset.BrowserPlayback != "" || asset.DurationSeconds != 0 {
		t.Fatalf("migration invented media probe history: %+v", asset)
	}
	if !strings.HasSuffix(asset.Path, "old.mp4") {
		t.Fatalf("legacy path lost: %+v", asset)
	}
}
