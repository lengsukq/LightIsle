package gallery

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

type testRenderer struct {
	mu       sync.Mutex
	calls    int
	data     []byte
	fail     bool
	started  chan struct{}
	release  chan struct{}
	lastRead []byte
	readErr  error
}

func TestThumbnailCacheHitAvoidsTemporarySourceCopy(t *testing.T) {
	// A correct cache hit must continue to hash the source bytes, while no
	// longer writing a redundant private 64 MiB worker input.
	env := newTestLibrary(t, []byte("cached-thumb"))
	modified := time.Unix(1_700_000_000, 0)
	writeTestPhoto(t, env.root, "photo.png", "abcdefgh", modified)
	id := scanAndPhotoID(t, env.library, "photo.png")
	copies := 0
	afterThumbnailSourceCopy = func(string) { copies++ }
	t.Cleanup(func() { afterThumbnailSourceCopy = nil })
	thumbnailBytes(t, env.library, id)
	if copies != 1 {
		t.Fatalf("initial render should copy source once; got %d", copies)
	}
	thumbnailBytes(t, env.library, id)
	if copies != 1 {
		t.Fatalf("cache hit wrote a redundant private input: %d", copies)
	}
	// Keep both length and mtime unchanged; hashing must still reject old
	// content and render a new JPEG when the actual bytes differ.
	env.renderer.setData([]byte("changed-thumb"))
	writeTestPhoto(t, env.root, "photo.png", "abcdEFGH", modified)
	if got := string(stripJPEGEnvelope(t, thumbnailBytes(t, env.library, id))); got != "changed-thumb" {
		t.Fatalf("same-metadata content replacement returned stale cache: %q", got)
	}
	if copies != 2 || env.renderer.callCount() != 2 {
		t.Fatalf("content change not safely rebuilt: copies=%d renders=%d", copies, env.renderer.callCount())
	}
}

func (r *testRenderer) Render(_ context.Context, input, output, _ string) error {
	contents, readErr := os.ReadFile(input)
	r.mu.Lock()
	r.calls++
	r.lastRead, r.readErr = contents, readErr
	data, fail := r.data, r.fail
	started, release := r.started, r.release
	r.mu.Unlock()
	if started != nil {
		started <- struct{}{}
	}
	if release != nil {
		<-release
	}
	if readErr != nil {
		return readErr
	}
	if fail {
		return errors.New("renderer unavailable")
	}
	return os.WriteFile(output, jpegEnvelope(data), 0600)
}

func (r *testRenderer) RenderSized(ctx context.Context, input, output, source string, maxPixel int) error {
	// The test fake ignores the size budget; the JPEG envelope is what the
	// validation layer sees either way.
	return r.Render(ctx, input, output, source)
}

type stubThumbnailWorker struct {
	err  error
	name string
	data []byte
}

func (w *stubThumbnailWorker) Thumbnail(_ context.Context, source *os.File, name, output string) (mediaworker.Metadata, error) {
	w.name = name
	if w.err != nil {
		return mediaworker.Metadata{}, w.err
	}
	if _, err := source.Stat(); err != nil {
		return mediaworker.Metadata{}, err
	}
	if err := os.WriteFile(output, w.data, 0600); err != nil {
		return mediaworker.Metadata{}, err
	}
	return mediaworker.Metadata{Status: "ok", Kind: "photo"}, nil
}

func (r *testRenderer) callCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.calls
}

func (r *testRenderer) setData(data []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.data = data
}

func (r *testRenderer) setFailure(fail bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.fail = fail
}

func (r *testRenderer) setHooks(started, release chan struct{}) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.started = started
	r.release = release
}

// inputContents reports the private worker file handed to the renderer.
func (r *testRenderer) inputContents() ([]byte, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.lastRead, r.readErr
}

// jpegEnvelope keeps the test seam deterministic while still producing the
// JPEG framing that cache validation requires.
func jpegEnvelope(data []byte) []byte {
	out := make([]byte, 0, len(data)+5)
	out = append(out, 0xFF, 0xD8, 0xFF)
	out = append(out, data...)
	return append(out, 0xFF, 0xD9)
}

func stripJPEGEnvelope(t *testing.T, data []byte) []byte {
	t.Helper()
	if len(data) < 5 || data[0] != 0xFF || data[1] != 0xD8 || data[2] != 0xFF || data[len(data)-2] != 0xFF || data[len(data)-1] != 0xD9 {
		t.Fatalf("thumbnail is not a JPEG envelope: %q", data)
	}
	return data[3 : len(data)-2]
}

type testClock struct{ current time.Time }

func (c *testClock) now() time.Time {
	c.current = c.current.Add(time.Second)
	return c.current
}

type testLibrary struct {
	library  *Library
	storage  *files.Manager
	renderer *testRenderer
	clock    *testClock
	root     string
}

func newTestLibrary(t *testing.T, output []byte) *testLibrary {
	t.Helper()
	root := t.TempDir()
	storage, err := files.NewManager(root)
	if err != nil {
		t.Fatal(err)
	}
	library, err := OpenWithOptions(root, storage, Options{})
	if err != nil {
		storage.Close()
		t.Fatal(err)
	}
	renderer := &testRenderer{data: output}
	clock := &testClock{current: time.Unix(1_700_000_000, 0)}
	library.renderer = renderer
	library.now = clock.now
	t.Cleanup(func() {
		library.Close()
		storage.Close()
	})
	return &testLibrary{library: library, storage: storage, renderer: renderer, clock: clock, root: root}
}

func writeTestPhoto(t *testing.T, root, name, contents string, modified time.Time) {
	t.Helper()
	path := filepath.Join(root, "SharedFiles", name)
	if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, modified, modified); err != nil {
		t.Fatal(err)
	}
}

func scanAndPhotoID(t *testing.T, library *Library, name string) int64 {
	t.Helper()
	if err := library.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for library.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if state := library.Status(); state.Running || state.LastError != "" {
		t.Fatalf("scan incomplete %+v", state)
	}
	assets, _, err := library.List(0, 60, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	for _, asset := range assets {
		if asset.Name == name {
			return asset.ID
		}
	}
	t.Fatalf("asset %s not indexed", name)
	return 0
}

func thumbnailBytes(t *testing.T, library *Library, id int64) []byte {
	t.Helper()
	file, err := library.Thumbnail(id)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	data, err := io.ReadAll(file)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func cacheKeyForPath(t *testing.T, cache, assetPath string) string {
	t.Helper()
	entries, err := os.ReadDir(cache)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		key, ok := thumbnailCacheKey(entry.Name())
		if !ok {
			continue
		}
		if meta, ok := readThumbnailMeta(cache, key); ok && meta.Path == assetPath {
			return key
		}
	}
	t.Fatalf("no cache entry for %s", assetPath)
	return ""
}

func legacyThumbnailKey(share, assetPath string, modified, size int64, sourceHash string) string {
	raw := share + "|" + assetPath + "|" + strconv.FormatInt(modified, 10) + "|" + strconv.FormatInt(size, 10) + "|" + sourceHash
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

func TestThumbnailCacheFormatUpgradeRebuildsLegacyOrientation(t *testing.T) {
	modified := time.Unix(1_700_000_000, 0)
	env := newTestLibrary(t, []byte("new-orientation-correct"))
	writeTestPhoto(t, env.root, "orientation.heic", "orientation-source", modified)
	id := scanAndPhotoID(t, env.library, "orientation.heic")
	asset, err := env.library.Asset(id)
	if err != nil {
		t.Fatal(err)
	}
	share, _ := env.storage.State()
	source, err := os.ReadFile(filepath.Join(share, asset.Path))
	if err != nil {
		t.Fatal(err)
	}
	sourceHash := sha256.Sum256(source)
	legacyKey := legacyThumbnailKey(share, asset.Path, asset.Modified, asset.Size, hex.EncodeToString(sourceHash[:]))
	legacyMeta := thumbnailMeta{
		Share: share, Path: asset.Path, Modified: asset.Modified, Size: asset.Size,
		SourceHash: hex.EncodeToString(sourceHash[:]), Kind: "photo",
	}
	legacyJPEG := jpegEnvelope([]byte("old-untransformed-orientation"))
	if err := os.WriteFile(filepath.Join(env.library.cache, legacyKey+".jpg"), legacyJPEG, 0600); err != nil {
		t.Fatal(err)
	}
	if err := writeThumbnailMeta(env.library.cache, legacyKey, legacyMeta); err != nil {
		t.Fatal(err)
	}
	if err := env.library.openThumbnailCache(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(env.library.cache, legacyKey+".jpg")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("startup retained legacy orientation cache: %v", err)
	}
	if _, err := os.Stat(thumbnailMetaPath(env.library.cache, legacyKey)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("startup retained legacy orientation sidecar: %v", err)
	}
	if env.library.cacheBytes != 0 || len(env.library.cacheEntries) != 0 {
		t.Fatalf("legacy cache remained indexed: bytes=%d entries=%d", env.library.cacheBytes, len(env.library.cacheEntries))
	}
	if got := string(stripJPEGEnvelope(t, thumbnailBytes(t, env.library, id))); got != "new-orientation-correct" {
		t.Fatalf("thumbnail served legacy orientation data %q", got)
	}
	if env.renderer.callCount() != 1 {
		t.Fatalf("new renderer was called %d times, want 1 rebuild", env.renderer.callCount())
	}
	newKey := cacheKeyForPath(t, env.library.cache, asset.Path)
	if newKey == legacyKey {
		t.Fatal("new cache format reused the legacy key")
	}
	meta, ok := readThumbnailMeta(env.library.cache, newKey)
	if !ok || meta.key() != newKey {
		t.Fatalf("new sidecar does not match its cache key: ok=%t meta=%+v key=%s", ok, meta, newKey)
	}
}

func TestThumbnailContentChangeWithSameSizeAndMtimeReRenders(t *testing.T) {
	first := time.Unix(1_700_000_000, 0)
	env := newTestLibrary(t, []byte("first-thumbnail"))
	writeTestPhoto(t, env.root, "photo.png", "same-length-a", first)
	id := scanAndPhotoID(t, env.library, "photo.png")
	if got := string(stripJPEGEnvelope(t, thumbnailBytes(t, env.library, id))); got != "first-thumbnail" {
		t.Fatalf("unexpected thumbnail %q", got)
	}
	asset, err := env.library.Asset(id)
	if err != nil {
		t.Fatal(err)
	}
	oldKey := cacheKeyForPath(t, env.library.cache, asset.Path)

	// Same byte length and identical mtime: only the content hash can tell the
	// two versions apart, so the cached JPEG must not be reused.
	env.renderer.setData([]byte("second-thumbnail"))
	writeTestPhoto(t, env.root, "photo.png", "same-length-b", first)
	scanAndPhotoID(t, env.library, "photo.png")
	if got := string(stripJPEGEnvelope(t, thumbnailBytes(t, env.library, id))); got != "second-thumbnail" {
		t.Fatalf("same-size/same-mtime rewrite served %q", got)
	}
	if env.renderer.callCount() != 2 {
		t.Fatalf("content change did not re-render: %d calls", env.renderer.callCount())
	}
	files := cachedJPEGFiles(t, env.library)
	if len(files) != 1 {
		t.Fatalf("expected only the new content version, got %v", files)
	}
	if files[0] == oldKey+".jpg" {
		t.Fatalf("stale content key %s survived", oldKey)
	}
	meta, ok := readThumbnailMeta(env.library.cache, strings.TrimSuffix(files[0], ".jpg"))
	if !ok {
		t.Fatalf("published entry lost its sidecar: %v", files)
	}
	if meta.SourceHash == "" || meta.key() != strings.TrimSuffix(files[0], ".jpg") {
		t.Fatalf("sidecar does not match published key: %+v", meta)
	}
}

func TestWorkerThumbnailRendererFallsBackOnlyForUnavailableOrUnsupported(t *testing.T) {
	for _, workerErr := range []error{mediaworker.ErrUnavailable, mediaworker.ErrUnsupported} {
		t.Run(workerErr.Error(), func(t *testing.T) {
			directory := t.TempDir()
			input := filepath.Join(directory, "private-input.heic")
			output := filepath.Join(directory, "private-output.jpg")
			if err := os.WriteFile(input, []byte("private-heic"), 0600); err != nil {
				t.Fatal(err)
			}
			placeholder, err := os.Create(output)
			if err != nil {
				t.Fatal(err)
			}
			placeholder.Close()
			worker := &stubThumbnailWorker{err: workerErr}
			fallback := &testRenderer{data: []byte("fallback")}
			renderer := workerThumbnailRenderer{worker: worker, fallback: fallback}
			if err := renderer.Render(context.Background(), input, output, "orientation.heic"); err != nil {
				t.Fatal(err)
			}
			if worker.name != "orientation.heic" || fallback.callCount() != 1 {
				t.Fatalf("worker name=%q fallback calls=%d", worker.name, fallback.callCount())
			}
			data, err := os.ReadFile(output)
			if err != nil || string(stripJPEGEnvelope(t, data)) != "fallback" {
				t.Fatalf("fallback output = %q, %v", data, err)
			}
		})
	}
}

func TestWorkerThumbnailRendererDoesNotHideMediaFailures(t *testing.T) {
	directory := t.TempDir()
	input := filepath.Join(directory, "private-input.heic")
	output := filepath.Join(directory, "private-output.jpg")
	if err := os.WriteFile(input, []byte("private-heic"), 0600); err != nil {
		t.Fatal(err)
	}
	placeholder, err := os.Create(output)
	if err != nil {
		t.Fatal(err)
	}
	placeholder.Close()
	worker := &stubThumbnailWorker{err: errors.New("corrupt media")}
	fallback := &testRenderer{data: []byte("fallback")}
	renderer := workerThumbnailRenderer{worker: worker, fallback: fallback}
	if err := renderer.Render(context.Background(), input, output, "corrupt.heic"); err == nil || err.Error() != "corrupt media" {
		t.Fatalf("render error = %v", err)
	}
	if fallback.callCount() != 0 {
		t.Fatalf("corrupt media unexpectedly used fallback %d times", fallback.callCount())
	}
}

func TestThumbnailEvictionAccountsForEntriesThatCannotBeRemoved(t *testing.T) {
	env := newTestLibrary(t, []byte("0123456789"))
	share, _ := env.storage.State()
	base := time.Unix(1_700_000_000, 0)
	keys := make([]string, 3)
	// Each entry is 15 bytes; the limit only fits two, so eviction must remove
	// the oldest and then cope with a delete that the filesystem rejects.
	for index := range keys {
		meta := thumbnailMeta{
			Share:      share,
			Path:       "photo-" + strconv.Itoa(index) + ".png",
			Modified:   base.Add(time.Duration(index) * time.Minute).UnixNano(),
			Size:       10,
			SourceHash: strings.Repeat("ab", sha256HexLength/2),
		}
		keys[index] = meta.key()
		if err := os.WriteFile(filepath.Join(env.library.cache, keys[index]+".jpg"), jpegEnvelope([]byte("0123456789")), 0600); err != nil {
			t.Fatal(err)
		}
		if err := writeThumbnailMeta(env.library.cache, keys[index], meta); err != nil {
			t.Fatal(err)
		}
		for _, name := range []string{keys[index] + ".jpg", keys[index] + ".meta"} {
			modified := base.Add(time.Duration(index) * time.Minute)
			if err := os.Chtimes(filepath.Join(env.library.cache, name), modified, modified); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := env.library.openThumbnailCache(); err != nil {
		t.Fatal(err)
	}
	env.library.cacheLimit = 30
	if env.library.cacheBytes != 45 || len(env.library.cacheEntries) != 3 {
		t.Fatalf("setup bytes=%d entries=%d", env.library.cacheBytes, len(env.library.cacheEntries))
	}

	original := removeThumbnailFile
	t.Cleanup(func() { removeThumbnailFile = original })
	removeThumbnailFile = func(name string) error {
		if filepath.Base(name) == keys[0]+".jpg" {
			return errors.New("resource busy")
		}
		return original(name)
	}
	err := env.library.evictThumbnailsLocked("")
	if err == nil || !strings.Contains(err.Error(), "thumbnail_cache_error") || !strings.Contains(err.Error(), "resource busy") {
		t.Fatalf("eviction error = %v", err)
	}
	key0, ok := parseThumbnailKeyHex(keys[0])
	if !ok {
		t.Fatalf("invalid key[0]: %q", keys[0])
	}
	if entry, ok := env.library.cacheEntries[key0]; !ok {
		t.Fatalf("entry whose delete failed was dropped from accounting")
	} else if entry.size != 15 {
		t.Fatalf("failed entry size = %d", entry.size)
	}
	if env.library.cacheBytes != 30 || len(env.library.cacheEntries) != 2 {
		t.Fatalf("after failed delete bytes=%d entries=%d, want 30/2", env.library.cacheBytes, len(env.library.cacheEntries))
	}
	if _, err := os.Stat(filepath.Join(env.library.cache, keys[0]+".jpg")); err != nil {
		t.Fatalf("failed delete removed the JPEG anyway: %v", err)
	}
	if _, err := os.Stat(filepath.Join(env.library.cache, keys[1]+".jpg")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("next victim was not evicted: %v", err)
	}

	// Once the filesystem cooperates the eviction converges instead of being
	// stuck on the skipped entry.
	removeThumbnailFile = original
	env.library.cacheLimit = 15
	if err := env.library.evictThumbnailsLocked(""); err != nil {
		t.Fatalf("retry eviction: %v", err)
	}
	if env.library.cacheBytes != 15 || len(env.library.cacheEntries) != 1 {
		t.Fatalf("retry bytes=%d entries=%d, want 15/1", env.library.cacheBytes, len(env.library.cacheEntries))
	}
	if _, ok := env.library.cacheEntries[key0]; ok {
		t.Fatalf("skipped entry was never retried")
	}
}

func TestThumbnailStartupDiscardsInvalidEntries(t *testing.T) {
	root := t.TempDir()
	storage, err := files.NewManager(root)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	cache := filepath.Join(root, "thumbnails")
	if err := os.MkdirAll(cache, 0700); err != nil {
		t.Fatal(err)
	}
	share, _ := storage.State()
	base := time.Unix(1_700_000_000, 0)
	metaFor := func(index int) thumbnailMeta {
		return thumbnailMeta{
			Share:      share,
			Path:       "orphan-" + strconv.Itoa(index) + ".png",
			Modified:   base.UnixNano(),
			Size:       10,
			SourceHash: strings.Repeat(strconv.Itoa(index), sha256HexLength),
		}
	}
	// A correctly named JPEG whose bytes are not a JPEG at all.
	corrupt := metaFor(0)
	if err := os.WriteFile(filepath.Join(cache, corrupt.key()+".jpg"), []byte("not-a-jpeg"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := writeThumbnailMeta(cache, corrupt.key(), corrupt); err != nil {
		t.Fatal(err)
	}
	// A valid JPEG that has no sidecar and therefore cannot be trusted.
	missingMeta := metaFor(1)
	if err := os.WriteFile(filepath.Join(cache, missingMeta.key()+".jpg"), jpegEnvelope([]byte("0123456789")), 0600); err != nil {
		t.Fatal(err)
	}
	// A sidecar whose JPEG never made it to disk.
	orphanMeta := metaFor(2)
	if err := writeThumbnailMeta(cache, orphanMeta.key(), orphanMeta); err != nil {
		t.Fatal(err)
	}
	// An empty file cannot satisfy the JPEG envelope even with a matching
	// sidecar.
	empty := metaFor(3)
	if err := os.WriteFile(filepath.Join(cache, empty.key()+".jpg"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := writeThumbnailMeta(cache, empty.key(), empty); err != nil {
		t.Fatal(err)
	}
	// A file beyond the per-thumbnail output ceiling is rejected by size before
	// its envelope is considered.
	oversized := metaFor(4)
	oversizedData := jpegEnvelope(make([]byte, maxThumbnailOutputBytes))
	if err := os.WriteFile(filepath.Join(cache, oversized.key()+".jpg"), oversizedData, 0600); err != nil {
		t.Fatal(err)
	}
	if err := writeThumbnailMeta(cache, oversized.key(), oversized); err != nil {
		t.Fatal(err)
	}

	library, err := OpenWithOptions(root, storage, Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer library.Close()
	if library.cacheBytes != 0 || len(library.cacheEntries) != 0 {
		t.Fatalf("invalid startup state bytes=%d entries=%d", library.cacheBytes, len(library.cacheEntries))
	}
	entries, err := os.ReadDir(cache)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("startup kept untrusted cache files: %v", entries)
	}

	// Rendering still works after the distrustful startup pass.
	library.renderer = &testRenderer{data: []byte("recovered")}
	library.now = (&testClock{current: base}).now
	writeTestPhoto(t, root, "photo.png", "source", base)
	id := scanAndPhotoID(t, library, "photo.png")
	if got := string(stripJPEGEnvelope(t, thumbnailBytes(t, library, id))); got != "recovered" {
		t.Fatalf("thumbnail after startup cleanup = %q", got)
	}
	if len(cachedJPEGFiles(t, library)) != 1 {
		t.Fatalf("recovered thumbnail was not cached")
	}
}

func TestThumbnailCorruptCacheHitIsRebuilt(t *testing.T) {
	env := newTestLibrary(t, []byte("thumbnail"))
	writeTestPhoto(t, env.root, "photo.png", "source", time.Unix(1_700_000_000, 0))
	id := scanAndPhotoID(t, env.library, "photo.png")
	thumbnailBytes(t, env.library, id)
	asset, err := env.library.Asset(id)
	if err != nil {
		t.Fatal(err)
	}
	key := cacheKeyForPath(t, env.library.cache, asset.Path)
	// Same length, so the tracked size still matches and only the JPEG envelope
	// check can reject it.
	if err := os.WriteFile(filepath.Join(env.library.cache, key+".jpg"), []byte(strings.Repeat("x", 14)), 0600); err != nil {
		t.Fatal(err)
	}
	if got := string(stripJPEGEnvelope(t, thumbnailBytes(t, env.library, id))); got != "thumbnail" {
		t.Fatalf("corrupt cache hit returned %q", got)
	}
	if env.renderer.callCount() != 2 {
		t.Fatalf("corrupt cache hit did not re-render: %d calls", env.renderer.callCount())
	}
	files := cachedJPEGFiles(t, env.library)
	if len(files) != 1 || files[0] != key+".jpg" {
		t.Fatalf("rebuilt cache = %v", files)
	}
	if err := validThumbnailPath(filepath.Join(env.library.cache, files[0])); err != nil {
		t.Fatalf("rebuilt entry is still invalid: %v", err)
	}
	if env.library.cacheBytes != 14 {
		t.Fatalf("cache bytes after rebuild = %d", env.library.cacheBytes)
	}
}
