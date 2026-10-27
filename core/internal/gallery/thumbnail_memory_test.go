package gallery

import (
	"fmt"
	"os"
	"path/filepath"
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
