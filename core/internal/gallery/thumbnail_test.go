package gallery

import (
	"context"
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

func (r *testRenderer) Render(_ context.Context, input, output string) error {
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
	if entry, ok := env.library.cacheEntries[keys[0]]; !ok {
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
	if _, ok := env.library.cacheEntries[keys[0]]; ok {
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

func TestThumbnailPruneDuringPublication(t *testing.T) {
	env := newTestLibrary(t, []byte("thumbnail"))
	writeTestPhoto(t, env.root, "photo.png", "source", time.Unix(1_700_000_000, 0))
	id := scanAndPhotoID(t, env.library, "photo.png")

	started := make(chan struct{}, 1)
	release := make(chan struct{})
	env.renderer.setHooks(started, release)
	rendered := make(chan error, 1)
	go func() {
		_, err := env.library.Thumbnail(id)
		rendered <- err
	}()
	select {
	case <-started:
	case <-time.After(10 * time.Second):
		t.Fatal("renderer never started")
	}

	// Remove the asset and let the scan delete its row while the conversion is
	// still in flight. The scan then blocks on thumbMu inside prune.
	if err := os.Remove(filepath.Join(env.root, "SharedFiles", "photo.png")); err != nil {
		t.Fatal(err)
	}
	if err := env.library.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		if _, err := env.library.Asset(id); err != nil {
			break
		}
		if time.Now().After(deadline) {
			close(release)
			t.Fatal("scan never removed the asset row")
		}
		time.Sleep(10 * time.Millisecond)
	}
	close(release)
	if err := <-rendered; err == nil || err.Error() != "asset_changed_rescan_required" {
		t.Fatalf("publication after prune = %v", err)
	}

	deadline = time.Now().Add(10 * time.Second)
	for env.library.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if state := env.library.Status(); state.Running || state.LastError != "" {
		t.Fatalf("scan incomplete %+v", state)
	}
	if files := cachedJPEGFiles(t, env.library); len(files) != 0 {
		t.Fatalf("pruned asset kept a thumbnail: %v", files)
	}
	if env.library.cacheBytes != 0 || len(env.library.cacheEntries) != 0 {
		t.Fatalf("stale accounting bytes=%d entries=%d", env.library.cacheBytes, len(env.library.cacheEntries))
	}
	entries, err := os.ReadDir(env.library.cache)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("publication and prune left artifacts: %v", entries)
	}
}

func TestThumbnailPruneKeepsLiveSourceCopy(t *testing.T) {
	env := newTestLibrary(t, []byte("thumbnail"))
	writeTestPhoto(t, env.root, "photo.png", "live-source", time.Unix(1_700_000_000, 0))
	id := scanAndPhotoID(t, env.library, "photo.png")

	var inputPath string
	copied := make(chan string, 1)
	resume := make(chan struct{})
	afterThumbnailSourceCopy = func(name string) {
		inputPath = name
		copied <- name
		<-resume
	}
	t.Cleanup(func() { afterThumbnailSourceCopy = nil })

	rendered := make(chan error, 1)
	go func() {
		_, err := env.library.Thumbnail(id)
		rendered <- err
	}()
	select {
	case <-copied:
	case <-time.After(10 * time.Second):
		t.Fatal("source copy never completed")
	}
	// The request has finished copying but has not reached the renderer yet.
	// A scan-prune cycle at this point must not unlink the registered worker
	// file, otherwise the renderer sees a missing input.
	env.library.pruneStaleThumbnails(mustShare(t, env.storage))
	if _, err := os.Stat(inputPath); err != nil {
		close(resume)
		t.Fatalf("prune removed live worker input %s: %v", inputPath, err)
	}
	close(resume)
	if err := <-rendered; err != nil {
		t.Fatalf("request after concurrent prune = %v", err)
	}
	if contents, err := env.renderer.inputContents(); err != nil || string(contents) != "live-source" {
		t.Fatalf("renderer input = %q, %v", contents, err)
	}
	entries, err := os.ReadDir(env.library.cache)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if thumbnailTempName(entry.Name()) {
			t.Fatalf("worker file survived publication: %s", entry.Name())
		}
	}
}

func TestThumbnailPruneDoesNotDeleteWorkerFilesOfAnotherRequest(t *testing.T) {
	env := newTestLibrary(t, []byte("thumbnail"))
	writeTestPhoto(t, env.root, "photo.png", "source", time.Unix(1_700_000_000, 0))
	id := scanAndPhotoID(t, env.library, "photo.png")

	live := filepath.Join(env.library.cache, thumbnailTempPrefix+"input-live")
	stale := filepath.Join(env.library.cache, thumbnailTempPrefix+"input-stale")
	for _, name := range []string{live, stale} {
		if err := os.WriteFile(name, []byte("worker"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	registered, err := env.library.createThumbnailTemp(thumbnailTempPrefix + "input-registered")
	if err != nil {
		t.Fatal(err)
	}
	registeredName := registered.Name()
	registered.Close()
	// Registration must be released by the request, not inferred from the
	// directory listing, so an unregistered leftover is still collected.
	env.library.pruneStaleThumbnails(mustShare(t, env.storage))
	if _, err := os.Stat(registeredName); err != nil {
		t.Fatalf("prune removed registered worker file: %v", err)
	}
	if _, err := os.Stat(live); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("unregistered worker file was kept: %v", err)
	}
	if _, err := os.Stat(stale); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale worker file was kept: %v", err)
	}
	env.library.releaseThumbnailTemp(registeredName)
	if _, err := os.Stat(registeredName); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("released worker file was kept: %v", err)
	}
	// The scan still works after the cleanup pass and the normal request path
	// publishes the entry.
	if got := string(stripJPEGEnvelope(t, thumbnailBytes(t, env.library, id))); got != "thumbnail" {
		t.Fatalf("thumbnail after prune = %q", got)
	}
}

func mustShare(t *testing.T, storage *files.Manager) string {
	t.Helper()
	share, online := storage.State()
	if !online {
		t.Fatal("share offline")
	}
	return share
}

func cachedJPEGFiles(t *testing.T, library *Library) []string {
	t.Helper()
	entries, err := os.ReadDir(library.cache)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, entry := range entries {
		if _, ok := thumbnailCacheKey(entry.Name()); ok {
			names = append(names, entry.Name())
		}
	}
	return names
}

func TestThumbnailCacheHitAndSourceVersionChange(t *testing.T) {
	first := time.Unix(1_700_000_000, 0)
	env := newTestLibrary(t, []byte("first-thumbnail"))
	writeTestPhoto(t, env.root, "photo.png", "first-source", first)
	id := scanAndPhotoID(t, env.library, "photo.png")

	if got := string(stripJPEGEnvelope(t, thumbnailBytes(t, env.library, id))); got != "first-thumbnail" {
		t.Fatalf("unexpected thumbnail %q", got)
	}
	if env.renderer.callCount() != 1 {
		t.Fatalf("renderer calls after first request = %d", env.renderer.callCount())
	}
	if got := string(stripJPEGEnvelope(t, thumbnailBytes(t, env.library, id))); got != "first-thumbnail" {
		t.Fatalf("unexpected cached thumbnail %q", got)
	}
	if env.renderer.callCount() != 1 {
		t.Fatalf("cache hit re-rendered: %d calls", env.renderer.callCount())
	}
	if files := cachedJPEGFiles(t, env.library); len(files) != 1 {
		t.Fatalf("expected one cached thumbnail, got %v", files)
	}

	env.renderer.setData([]byte("second-thumbnail"))
	writeTestPhoto(t, env.root, "photo.png", "second-source-with-new-size", first.Add(time.Hour))
	id = scanAndPhotoID(t, env.library, "photo.png")
	if got := string(stripJPEGEnvelope(t, thumbnailBytes(t, env.library, id))); got != "second-thumbnail" {
		t.Fatalf("unexpected re-rendered thumbnail %q", got)
	}
	if env.renderer.callCount() != 2 {
		t.Fatalf("source version change did not re-render: %d calls", env.renderer.callCount())
	}
	if files := cachedJPEGFiles(t, env.library); len(files) != 1 {
		t.Fatalf("stale thumbnail version was not pruned: %v", files)
	}
}

func TestThumbnailCacheLRUEviction(t *testing.T) {
	env := newTestLibrary(t, []byte("0123456789"))
	// Each render is 15 bytes with the JPEG envelope, so the budget holds three.
	env.library.cacheLimit = 45
	names := []string{"a.png", "b.png", "c.png", "d.png"}
	ids := map[string]int64{}
	base := time.Unix(1_700_000_000, 0)
	for index, name := range names {
		writeTestPhoto(t, env.root, name, "source-"+name, base.Add(time.Duration(index)*time.Minute))
	}
	if err := env.library.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for env.library.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if state := env.library.Status(); state.Running || state.LastError != "" {
		t.Fatalf("scan incomplete %+v", state)
	}
	assets, _, err := env.library.List(0, 60, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	for _, asset := range assets {
		ids[asset.Name] = asset.ID
	}
	for _, name := range names[:3] {
		thumbnailBytes(t, env.library, ids[name])
	}
	if env.renderer.callCount() != 3 {
		t.Fatalf("expected three renders, got %d", env.renderer.callCount())
	}
	// Touch the oldest entry so the second becomes the LRU victim.
	thumbnailBytes(t, env.library, ids["a.png"])
	if env.renderer.callCount() != 3 {
		t.Fatalf("cache hit after touching oldest re-rendered: %d", env.renderer.callCount())
	}
	thumbnailBytes(t, env.library, ids["d.png"])
	if env.renderer.callCount() != 4 {
		t.Fatalf("expected fourth render, got %d", env.renderer.callCount())
	}
	if got := len(cachedJPEGFiles(t, env.library)); got != 3 {
		t.Fatalf("cache holds %d thumbnails, want 3", got)
	}
	thumbnailBytes(t, env.library, ids["b.png"])
	if env.renderer.callCount() != 5 {
		t.Fatalf("LRU victim was not evicted: %d renders", env.renderer.callCount())
	}
	thumbnailBytes(t, env.library, ids["a.png"])
	if env.renderer.callCount() != 5 {
		t.Fatalf("recently used entry was evicted: %d renders", env.renderer.callCount())
	}
}

func TestThumbnailCacheConversionFailureLeavesNoArtifacts(t *testing.T) {
	env := newTestLibrary(t, []byte("thumbnail"))
	writeTestPhoto(t, env.root, "photo.png", "source", time.Unix(1_700_000_000, 0))
	id := scanAndPhotoID(t, env.library, "photo.png")
	env.renderer.setFailure(true)
	if _, err := env.library.Thumbnail(id); err == nil || err.Error() != "thumbnail_conversion_failed" {
		t.Fatalf("conversion failure = %v", err)
	}
	if files := cachedJPEGFiles(t, env.library); len(files) != 0 {
		t.Fatalf("failed conversion published cache files %v", files)
	}
	entries, err := os.ReadDir(env.library.cache)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		t.Fatalf("failed conversion left artifact %s", entry.Name())
	}
	env.renderer.setFailure(false)
	if got := string(stripJPEGEnvelope(t, thumbnailBytes(t, env.library, id))); got != "thumbnail" {
		t.Fatalf("retry after failure returned %q", got)
	}
}

func TestThumbnailCacheRebuildFromDiskEnforcesBudget(t *testing.T) {
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
	keys := make([]string, 3)
	// The newest file must survive when the restored budget only fits one.
	for index := range keys {
		meta := thumbnailMeta{
			Share:      share,
			Path:       "photo-" + strconv.Itoa(index) + ".png",
			Modified:   base.Add(time.Duration(index) * time.Minute).UnixNano(),
			Size:       10,
			SourceHash: strings.Repeat(strconv.Itoa(index), sha256HexLength),
		}
		keys[index] = meta.key()
		if err := os.WriteFile(filepath.Join(cache, keys[index]+".jpg"), jpegEnvelope([]byte("0123456789")), 0600); err != nil {
			t.Fatal(err)
		}
		if err := writeThumbnailMeta(cache, keys[index], meta); err != nil {
			t.Fatal(err)
		}
		modified := base.Add(time.Duration(index) * time.Minute)
		for _, name := range []string{keys[index] + ".jpg", keys[index] + ".meta"} {
			if err := os.Chtimes(filepath.Join(cache, name), modified, modified); err != nil {
				t.Fatal(err)
			}
		}
	}
	library, err := OpenWithOptions(root, storage, Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer library.Close()
	library.cacheLimit = 15
	if err := library.openThumbnailCache(); err != nil {
		t.Fatal(err)
	}
	files, err := os.ReadDir(cache)
	if err != nil {
		t.Fatal(err)
	}
	thumbnails := 0
	var kept string
	for _, file := range files {
		if _, ok := thumbnailCacheKey(file.Name()); ok {
			thumbnails++
			kept = file.Name()
		}
	}
	if thumbnails != 1 || kept != keys[2]+".jpg" {
		t.Fatalf("restored cache kept %v, want newest entry only", files)
	}
	if library.cacheBytes != 15 {
		t.Fatalf("tracked cache bytes = %d", library.cacheBytes)
	}
	// A second startup load must rebuild, not double-count, the same files.
	if err := library.openThumbnailCache(); err != nil {
		t.Fatal(err)
	}
	if len(library.cacheEntries) != 1 || library.cacheBytes != 15 {
		t.Fatalf("second startup load doubled state: entries=%d bytes=%d", len(library.cacheEntries), library.cacheBytes)
	}
}

func TestThumbnailLargerThanCacheBudgetIsServedUncached(t *testing.T) {
	env := newTestLibrary(t, []byte("0123456789"))
	env.library.cacheLimit = 5
	writeTestPhoto(t, env.root, "photo.png", "source", time.Unix(1_700_000_000, 0))
	id := scanAndPhotoID(t, env.library, "photo.png")
	if got := string(stripJPEGEnvelope(t, thumbnailBytes(t, env.library, id))); got != "0123456789" {
		t.Fatalf("oversized thumbnail = %q", got)
	}
	if files := cachedJPEGFiles(t, env.library); len(files) != 0 {
		t.Fatalf("oversized thumbnail was published to cache: %v", files)
	}
	if env.library.cacheBytes != 0 {
		t.Fatalf("oversized thumbnail counted against budget: %d", env.library.cacheBytes)
	}
	// The next request re-renders instead of serving an over-budget entry.
	thumbnailBytes(t, env.library, id)
	if env.renderer.callCount() != 2 {
		t.Fatalf("oversized thumbnail was cached: %d renders", env.renderer.callCount())
	}
}

func TestThumbnailPruneRemovesOnlyStaleVersions(t *testing.T) {
	first := time.Unix(1_700_000_000, 0)
	env := newTestLibrary(t, []byte("thumbnail"))
	writeTestPhoto(t, env.root, "keep.png", "keep-source", first)
	writeTestPhoto(t, env.root, "drop.png", "drop-source", first)
	keepID := scanAndPhotoID(t, env.library, "keep.png")
	dropID := scanAndPhotoID(t, env.library, "drop.png")
	thumbnailBytes(t, env.library, keepID)
	thumbnailBytes(t, env.library, dropID)
	if files := cachedJPEGFiles(t, env.library); len(files) != 2 {
		t.Fatalf("expected two cached thumbnails, got %v", files)
	}
	if err := os.Remove(filepath.Join(env.root, "SharedFiles", "drop.png")); err != nil {
		t.Fatal(err)
	}
	if err := env.library.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for env.library.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if state := env.library.Status(); state.Running || state.LastError != "" {
		t.Fatalf("scan incomplete %+v", state)
	}
	if files := cachedJPEGFiles(t, env.library); len(files) != 1 {
		t.Fatalf("prune kept %v, want only the indexed thumbnail", files)
	}
	thumbnailBytes(t, env.library, keepID)
	if env.renderer.callCount() != 2 {
		t.Fatalf("prune removed a valid thumbnail: %d renders", env.renderer.callCount())
	}
}

func TestThumbnailCacheLimitValidationAndStartupCleanup(t *testing.T) {
	if _, err := OpenWithOptions(t.TempDir(), nil, Options{ThumbnailCacheBytes: MinThumbnailCacheBytes - 1}); !errors.Is(err, ErrThumbnailCacheLimit) {
		t.Fatalf("below-minimum limit = %v", err)
	}
	if _, err := OpenWithOptions(t.TempDir(), nil, Options{ThumbnailCacheBytes: MaxThumbnailCacheBytes + 1}); !errors.Is(err, ErrThumbnailCacheLimit) {
		t.Fatalf("above-maximum limit = %v", err)
	}

	for _, limit := range []int64{MinThumbnailCacheBytes, MaxThumbnailCacheBytes} {
		root := t.TempDir()
		storage, err := files.NewManager(root)
		if err != nil {
			t.Fatal(err)
		}
		cache := filepath.Join(root, "thumbnails")
		if err := os.MkdirAll(cache, 0700); err != nil {
			t.Fatal(err)
		}
		for _, name := range []string{"tmp-input-123", "tmp-thumb-123", "input-123", "thumb-123"} {
			if err := os.WriteFile(filepath.Join(cache, name), []byte("leftover"), 0600); err != nil {
				t.Fatal(err)
			}
		}
		library, err := OpenWithOptions(root, storage, Options{ThumbnailCacheBytes: limit})
		if err != nil {
			storage.Close()
			t.Fatalf("limit %d rejected: %v", limit, err)
		}
		if library.cacheLimit != limit {
			t.Fatalf("cache limit = %d, want %d", library.cacheLimit, limit)
		}
		entries, err := os.ReadDir(cache)
		if err != nil {
			library.Close()
			storage.Close()
			t.Fatal(err)
		}
		if len(entries) != 0 {
			library.Close()
			storage.Close()
			t.Fatalf("startup left temporary files: %v", entries)
		}
		library.Close()
		storage.Close()
	}

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
	if library.cacheLimit != DefaultThumbnailCacheBytes {
		library.Close()
		storage.Close()
		t.Fatalf("default cache limit = %d", library.cacheLimit)
	}
	library.Close()
	storage.Close()
}
