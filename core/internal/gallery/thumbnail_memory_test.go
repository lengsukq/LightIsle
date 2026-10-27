package gallery

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestThumbnailEntryBudgetKeepsRecentCacheAndOriginals(t *testing.T) {
	env := newTestLibrary(t, []byte("thumb"))
	env.library.cacheEntryLimit = 2
	for i := 0; i < 3; i++ {
		name := fmt.Sprintf("photo-%d.png", i)
		writeTestPhoto(t, env.root, name, "original", time.Unix(1700000000+int64(i), 0))
		id := scanAndPhotoID(t, env.library, name)
		env.clock.current = env.clock.current.Add(time.Minute)
		thumbnailBytes(t, env.library, id)
	}
	if len(env.library.cacheEntries) != 2 {
		t.Fatalf("entries=%d", len(env.library.cacheEntries))
	}
	for i := 0; i < 3; i++ {
		if raw, err := os.ReadFile(filepath.Join(env.root, "SharedFiles", fmt.Sprintf("photo-%d.png", i))); err != nil || string(raw) != "original" {
			t.Fatalf("original changed: %q %v", raw, err)
		}
	}
	if err := env.library.openThumbnailCache(); err != nil {
		t.Fatal(err)
	}
	if len(env.library.cacheEntries) != 2 {
		t.Fatal("restart did not enforce entry limit")
	}
	// An evicted image remains usable and can regenerate its cache.
	id := scanAndPhotoID(t, env.library, "photo-0.png")
	thumbnailBytes(t, env.library, id)
	if len(env.library.cacheEntries) != 2 {
		t.Fatal("regeneration exceeded entry limit")
	}
}

func TestThumbnailStartupEntryBudgetStreamsDirectoryAndRetainsNewest(t *testing.T) {
	env := newTestLibrary(t, []byte("thumb"))
	env.library.cacheEntryLimit = 3
	newest := ""
	for i := 0; i < 800; i++ {
		meta := thumbnailMeta{Share: "/share", Path: fmt.Sprintf("%d.png", i), Modified: 1, Size: 1, SourceHash: strings.Repeat("a", 64)}
		key := meta.key()
		newest = key
		name := filepath.Join(env.library.cache, key+".jpg")
		if err := os.WriteFile(name, jpegEnvelope([]byte("small")), 0600); err != nil {
			t.Fatal(err)
		}
		if err := writeThumbnailMeta(env.library.cache, key, meta); err != nil {
			t.Fatal(err)
		}
		at := time.Unix(1700000000+int64(i), 0)
		if err := os.Chtimes(name, at, at); err != nil {
			t.Fatal(err)
		}
	}
	if err := env.library.openThumbnailCache(); err != nil {
		t.Fatal(err)
	}
	if len(env.library.cacheEntries) != 3 {
		t.Fatalf("entries=%d", len(env.library.cacheEntries))
	}
	if _, ok := env.library.cacheEntries[newest]; !ok {
		t.Fatal("streaming eviction removed the newest cache")
	}
	entries, err := os.ReadDir(env.library.cache)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 6 {
		t.Fatalf("orphan sidecars survived: %d files", len(entries))
	}
}

// A local, synthetic index sample. No originals/media downloads are needed.
func BenchmarkThumbnailIndexMemory(b *testing.B) {
	for _, count := range []int{10_000, 50_000} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				entries := make(map[string]thumbnailCacheEntry, count)
				for j := 0; j < count; j++ {
					entries[fmt.Sprintf("%064x", j)] = thumbnailCacheEntry{size: 100, used: time.Unix(int64(j), 0), identity: fmt.Sprintf("%064x", j+count)}
				}
				if len(entries) != count {
					b.Fatal("index size mismatch")
				}
			}
		})
	}
}

func TestThumbnailUndeletableCacheDoesNotGrowIndex(t *testing.T) {
	env := newTestLibrary(t, []byte("thumb"))
	env.library.cacheEntryLimit = 1
	writeTestPhoto(t, env.root, "old.png", "original", time.Unix(1700000000, 0))
	oldID := scanAndPhotoID(t, env.library, "old.png")
	thumbnailBytes(t, env.library, oldID)
	var oldKey string
	for key := range env.library.cacheEntries {
		oldKey = key
	}
	originalRemove := removeThumbnailFile
	removeThumbnailFile = func(path string) error {
		if filepath.Base(path) == oldKey+".jpg" {
			return os.ErrPermission
		}
		return originalRemove(path)
	}
	defer func() { removeThumbnailFile = originalRemove }()
	for i := 0; i < 3; i++ {
		name := fmt.Sprintf("uncached-%d.png", i)
		writeTestPhoto(t, env.root, name, "original", time.Unix(1700000000, 0))
		id := scanAndPhotoID(t, env.library, name)
		thumbnailBytes(t, env.library, id)
		if len(env.library.cacheEntries) != 1 {
			t.Fatalf("failed eviction grew heap index: %d", len(env.library.cacheEntries))
		}
	}
}

// Real directory entries and sidecars, generated locally. Run with -benchtime=1x
// to measure a cold index rebuild without downloading or decoding photo media.
func BenchmarkThumbnailCacheStartup(b *testing.B) {
	for _, count := range []int{10_000, 50_000} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			cache := b.TempDir()
			for i := 0; i < count; i++ {
				meta := thumbnailMeta{Share: "/synthetic-library", Path: fmt.Sprintf("photo-%d.jpg", i), Modified: int64(i + 1), Size: 100, SourceHash: fmt.Sprintf("%064x", i)}
				key := meta.key()
				if err := os.WriteFile(filepath.Join(cache, key+".jpg"), jpegEnvelope([]byte("synthetic")), 0600); err != nil {
					b.Fatal(err)
				}
				if err := writeThumbnailMeta(cache, key, meta); err != nil {
					b.Fatal(err)
				}
			}
			b.ReportAllocs()
			b.ResetTimer()
			var retained uint64
			for i := 0; i < b.N; i++ {
				b.StopTimer()
				library := &Library{cache: cache, cacheLimit: DefaultThumbnailCacheBytes, workerTemp: map[string]struct{}{}}
				runtime.GC() // Measurement only; never part of production cache management.
				var before, after runtime.MemStats
				runtime.ReadMemStats(&before)
				b.StartTimer()
				if err := library.openThumbnailCache(); err != nil {
					b.Fatal(err)
				}
				b.StopTimer()
				if len(library.cacheEntries) != count {
					b.Fatalf("startup indexed %d of %d entries", len(library.cacheEntries), count)
				}
				runtime.GC()
				runtime.ReadMemStats(&after)
				if after.HeapAlloc > before.HeapAlloc {
					retained += after.HeapAlloc - before.HeapAlloc
				}
				runtime.KeepAlive(library)
			}
			b.ReportMetric(float64(retained)/float64(b.N), "retained-heap-B")
		})
	}
}

func TestThumbnailOversizedSidecarIsRejectedBeforeIndexing(t *testing.T) {
	env := newTestLibrary(t, []byte("thumb"))
	meta := thumbnailMeta{Share: "/share", Path: "photo.jpg", Modified: 1, Size: 1, SourceHash: strings.Repeat("a", 64)}
	key := meta.key()
	jpeg := filepath.Join(env.library.cache, key+".jpg")
	if err := os.WriteFile(jpeg, jpegEnvelope([]byte("small")), 0600); err != nil {
		t.Fatal(err)
	}
	file, err := os.Create(thumbnailMetaPath(env.library.cache, key))
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(32 << 20); err != nil {
		file.Close()
		t.Fatal(err)
	}
	file.Close()
	if _, ok := readThumbnailMeta(env.library.cache, key); ok {
		t.Fatal("oversized metadata accepted")
	}
	if err := env.library.openThumbnailCache(); err != nil {
		t.Fatal(err)
	}
	if len(env.library.cacheEntries) != 0 {
		t.Fatal("invalid cache remained indexed")
	}
	if _, err := os.Stat(jpeg); !os.IsNotExist(err) {
		t.Fatalf("invalid regenerable JPEG was retained: %v", err)
	}
}
