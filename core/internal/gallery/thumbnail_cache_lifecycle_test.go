package gallery

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

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
