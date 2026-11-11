package gallery

import (
	"bytes"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

func validThumbnailCacheLimit(limit int64) bool {
	return limit >= MinThumbnailCacheBytes && limit <= MaxThumbnailCacheBytes
}

// openThumbnailCache rebuilds the size index from disk, removes leftover
// worker files and entries that no longer hold a valid JPEG envelope, and
// enforces the configured budget before the first request. Cache files are only
// trusted together with their matching sidecar; a missing or forged sidecar is
// removed along with the JPEG.
// walkThumbnailDirectory avoids materializing every directory entry (JPEGs,
// sidecars and temps) at once. Cache directories can contain many small files.
func (l *Library) walkThumbnailDirectory(visit func(os.DirEntry) error) error {
	dir, err := os.Open(l.cache)
	if err != nil {
		return err
	}
	defer dir.Close()
	for {
		entries, err := dir.ReadDir(256)
		for _, entry := range entries {
			if err := visit(entry); err != nil {
				return err
			}
		}
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

func (l *Library) openThumbnailCache() error {
	if err := os.MkdirAll(l.cache, 0700); err != nil {
		return err
	}
	l.cleanupThumbnailTempFiles()
	l.cacheMu.Lock()
	defer l.cacheMu.Unlock()
	l.cacheEntries = map[[32]byte]thumbnailCacheEntry{}
	l.cacheBytes = 0
	if err := l.walkThumbnailDirectory(func(entry os.DirEntry) error {
		if entry.IsDir() {
			return nil
		}
		hexKey, ok := thumbnailCacheKey(entry.Name())
		if !ok {
			return nil
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() || validThumbnailPath(filepath.Join(l.cache, entry.Name())) != nil {
			if err := removeThumbnailCacheFiles(l.cache, hexKey); err != nil {
				return thumbnailCacheError(err)
			}
			return nil
		}
		meta, ok := readThumbnailMeta(l.cache, hexKey)
		if !ok {
			if err := removeThumbnailCacheFiles(l.cache, hexKey); err != nil {
				return thumbnailCacheError(err)
			}
			return nil
		}
		key, ok := parseThumbnailKeyHex(hexKey)
		if !ok {
			if err := removeThumbnailCacheFiles(l.cache, hexKey); err != nil {
				return thumbnailCacheError(err)
			}
			return nil
		}
		l.cacheEntries[key] = thumbnailCacheEntry{
			size:         info.Size(),
			used:         info.ModTime(),
			identityHash: hashThumbnailIdentity(meta.identity()),
		}
		l.cacheBytes += info.Size()
		// A modest batch margin amortizes LRU sorting while bounding startup
		// heap even when an old directory far exceeds the entry limit.
		if len(l.cacheEntries) >= l.thumbnailEntryLimit()+256 {
			return l.evictThumbnailsLocked("")
		}
		return nil
	}); err != nil {
		return err
	}
	if err := l.evictThumbnailsLocked(""); err != nil {
		return err
	}
	return l.walkThumbnailDirectory(func(entry os.DirEntry) error {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".meta") {
			return nil
		}
		hexKey := strings.TrimSuffix(entry.Name(), ".meta")
		key, ok := parseThumbnailKeyHex(hexKey)
		if !ok {
			if err := removeThumbnailFile(filepath.Join(l.cache, entry.Name())); err != nil && !errors.Is(err, os.ErrNotExist) {
				return thumbnailCacheError(err)
			}
			return nil
		}
		if _, present := l.cacheEntries[key]; !present {
			if err := removeThumbnailFile(filepath.Join(l.cache, entry.Name())); err != nil && !errors.Is(err, os.ErrNotExist) {
				return thumbnailCacheError(err)
			}
		}
		return nil
	})
}

// removeThumbnailCacheFiles deletes an untracked cache pair. Accounting is not
// touched; callers that own an entry must use removeThumbnailEntryLocked.
func removeThumbnailCacheFiles(cache, key string) error {
	err := removeThumbnailFile(filepath.Join(cache, key+".jpg"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	_ = removeThumbnailFile(thumbnailMetaPath(cache, key))
	return nil
}

func thumbnailCacheKey(name string) (string, bool) {
	const suffix = ".jpg"
	if len(name) != sha256HexLength+len(suffix) || !strings.HasSuffix(name, suffix) {
		return "", false
	}
	key := strings.TrimSuffix(name, suffix)
	if _, err := hex.DecodeString(key); err != nil {
		return "", false
	}
	return key, true
}

const sha256HexLength = 64

func (l *Library) cleanupThumbnailTempFiles() {
	l.workerMu.Lock()
	defer l.workerMu.Unlock()
	_ = l.walkThumbnailDirectory(func(entry os.DirEntry) error {
		if entry.IsDir() || !thumbnailTempName(entry.Name()) {
			return nil
		}
		name := filepath.Join(l.cache, entry.Name())
		if _, live := l.workerTemp[name]; !live {
			_ = removeThumbnailFile(name)
		}
		return nil
	})
}

// createThumbnailTemp registers the new worker file in the same critical
// section as its creation, so a concurrent cleanup can never observe the file
// and then delete it after the request has started using it.
func (l *Library) createThumbnailTemp(pattern string) (*os.File, error) {
	l.workerMu.Lock()
	defer l.workerMu.Unlock()
	tmp, err := os.CreateTemp(l.cache, pattern)
	if err != nil {
		return nil, err
	}
	l.workerTemp[tmp.Name()] = struct{}{}
	return tmp, nil
}

func (l *Library) releaseThumbnailTemp(name string) {
	l.workerMu.Lock()
	delete(l.workerTemp, name)
	l.workerMu.Unlock()
	_ = os.Remove(name)
}

func (l *Library) cachedThumbnail(hexKey, identity string) (*os.File, bool) {
	key, ok := parseThumbnailKeyHex(hexKey)
	if !ok {
		return nil, false
	}
	idHash := hashThumbnailIdentity(identity)
	destination := filepath.Join(l.cache, hexKey+".jpg")
	l.cacheMu.Lock()
	entry, ok := l.cacheEntries[key]
	if !ok {
		l.cacheMu.Unlock()
		return nil, false
	}
	if entry.identityHash != idHash {
		_ = l.removeThumbnailEntryLocked(key, entry)
		l.cacheMu.Unlock()
		return nil, false
	}
	f, err := os.Open(destination)
	if err == nil {
		var info os.FileInfo
		if info, err = f.Stat(); err == nil {
			if !info.Mode().IsRegular() || info.Size() != entry.size || info.Size() <= 0 || info.Size() > maxThumbnailOutputBytes {
				err = errors.New("thumbnail_cache_entry_invalid")
			} else {
				err = validateThumbnailFile(f, info.Size())
			}
		}
	}
	if err != nil {
		if f != nil {
			f.Close()
		}
		_ = l.removeThumbnailEntryLocked(key, entry)
		l.cacheMu.Unlock()
		return nil, false
	}
	entry.used = l.nowTime()
	l.cacheEntries[key] = entry
	// Persist the access timestamp so a restart rebuilds the same LRU order.
	_ = os.Chtimes(destination, entry.used, entry.used)
	l.cacheMu.Unlock()
	return f, true
}

func (l *Library) recordThumbnail(hexKey, identity string, size int64) error {
	key, ok := parseThumbnailKeyHex(hexKey)
	if !ok {
		return errors.New("thumbnail_invalid_key")
	}
	idHash := hashThumbnailIdentity(identity)
	used := l.nowTime()
	l.cacheMu.Lock()
	defer l.cacheMu.Unlock()
	if previous, ok := l.cacheEntries[key]; ok {
		l.cacheBytes -= previous.size
	}
	// A content replacement keeps the same asset identity but gets a new key.
	// Drop older renders of that identity so at most one version is retained.
	for other, entry := range l.cacheEntries {
		if other != key && entry.identityHash == idHash {
			_ = l.removeThumbnailEntryLocked(other, entry)
		}
	}
	l.cacheEntries[key] = thumbnailCacheEntry{size: size, used: used, identityHash: idHash}
	l.cacheBytes += size
	_ = os.Chtimes(filepath.Join(l.cache, hexKey+".jpg"), used, used)
	return l.evictThumbnailsToLocked(&key, l.thumbnailEntryLimit())
}

// removeThumbnailEntryLocked deletes the JPEG and its sidecar and updates the
// accounting. The entry remains indexed and counted when the filesystem refuses
// the delete, so the budget still reflects bytes present on disk.
func (l *Library) removeThumbnailEntryLocked(key [32]byte, entry thumbnailCacheEntry) error {
	hexKey := formatThumbnailKeyHex(key)
	err := removeThumbnailFile(filepath.Join(l.cache, hexKey+".jpg"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	_ = removeThumbnailFile(thumbnailMetaPath(l.cache, hexKey))
	delete(l.cacheEntries, key)
	l.cacheBytes -= entry.size
	if l.cacheBytes < 0 {
		l.cacheBytes = 0
	}
	return nil
}

// evictThumbnailsLocked removes least-recently-used entries until the total
// fits the budget. keepKey protects the entry just published even if every
// timestamp is identical. Entries whose files cannot be deleted stay indexed
// and counted, and the loop moves on to other victims; failure to free enough
// space is reported so callers do not silently exceed the budget.
func (l *Library) thumbnailEntryLimit() int {
	if l.cacheEntryLimit > 0 {
		return l.cacheEntryLimit
	}
	return MaxThumbnailCacheEntries
}

// Called under thumbMu before publishing a new cache pair. If existing cache
// files cannot be deleted, serve the renderer's temporary file uncached instead
// of growing the heap index on every subsequent request.
func (l *Library) prepareThumbnailCache(hexKey string) bool {
	key, ok := parseThumbnailKeyHex(hexKey)
	if !ok {
		return false
	}
	l.cacheMu.Lock()
	defer l.cacheMu.Unlock()
	limit := l.thumbnailEntryLimit()
	if _, exists := l.cacheEntries[key]; exists || len(l.cacheEntries) < limit {
		return true
	}
	_ = l.evictThumbnailsToLocked(nil, limit-1)
	return len(l.cacheEntries) < limit
}

func (l *Library) evictThumbnailsLocked(keepHexKey string) error {
	var keepKey *[32]byte
	if parsed, ok := parseThumbnailKeyHex(keepHexKey); ok {
		keepKey = &parsed
	}
	return l.evictThumbnailsToLocked(keepKey, l.thumbnailEntryLimit())
}

func (l *Library) evictThumbnailsToLocked(keepKey *[32]byte, limit int) error {
	if l.cacheBytes <= l.cacheLimit && len(l.cacheEntries) <= limit {
		return nil
	}
	// At the entry cap, admitting one new thumbnail normally needs just one
	// victim. Avoid copying and sorting the entire (up to 50k entry) index.
	// Bulk byte-budget eviction and failed deletes use the sorted fallback.
	if l.cacheBytes <= l.cacheLimit && len(l.cacheEntries) == limit+1 {
		var oldestKey [32]byte
		var oldest thumbnailCacheEntry
		hasOldest := false
		for key, entry := range l.cacheEntries {
			if keepKey != nil && key == *keepKey {
				continue
			}
			if !hasOldest || entry.used.Before(oldest.used) ||
				(entry.used.Equal(oldest.used) && bytes.Compare(key[:], oldestKey[:]) < 0) {
				oldestKey, oldest, hasOldest = key, entry, true
			}
		}
		if hasOldest {
			if err := l.removeThumbnailEntryLocked(oldestKey, oldest); err == nil {
				return nil
			}
		}
	}
	type candidate struct {
		key   [32]byte
		entry thumbnailCacheEntry
	}
	victims := make([]candidate, 0, len(l.cacheEntries))
	for key, entry := range l.cacheEntries {
		if keepKey == nil || key != *keepKey {
			victims = append(victims, candidate{key, entry})
		}
	}
	// Sort once rather than scanning the whole map for every evicted entry.
	sort.Slice(victims, func(i, j int) bool {
		if victims[i].entry.used.Equal(victims[j].entry.used) {
			return bytes.Compare(victims[i].key[:], victims[j].key[:]) < 0
		}
		return victims[i].entry.used.Before(victims[j].entry.used)
	})
	var lastErr error
	for _, victim := range victims {
		if l.cacheBytes <= l.cacheLimit && len(l.cacheEntries) <= limit {
			break
		}
		if err := l.removeThumbnailEntryLocked(victim.key, victim.entry); err != nil {
			lastErr = err
		}
	}
	if lastErr != nil {
		return thumbnailCacheError(lastErr)
	}
	return nil
}

// pruneStaleThumbnails drops cache entries whose source version no longer
// exists in the index. It runs after a clean full scan, so partial walks never
// discard entries for assets that simply were not visited yet. Cache keys
// contain a content hash that the index does not store, so the sidecar identity
// is used to match keys to rows; when content changed without a metadata change,
// the newest entry for that identity wins and older keys are discarded.
func (l *Library) pruneStaleThumbnails(share string) {
	// Freeze cache publication before collecting identities. Only cache-sized
	// state is needed, regardless of the total number of indexed originals.
	if err := l.thumbMu.lock(l.ctx); err != nil {
		return
	}
	defer l.thumbMu.unlock()
	l.cleanupThumbnailTempFiles()
	l.cacheMu.Lock()
	valid := make(map[[16]byte]bool, len(l.cacheEntries))
	for _, entry := range l.cacheEntries {
		valid[entry.identityHash] = false
	}
	l.cacheMu.Unlock()
	if len(valid) == 0 {
		return
	}
	rows, err := l.db.Query("SELECT path,modified,size FROM assets WHERE share=? AND missing_path=''", share)
	if err != nil {
		return
	}
	for rows.Next() {
		var path string
		var modified, size int64
		if rows.Scan(&path, &modified, &size) == nil {
			idHash := hashThumbnailIdentity(cacheID(share, path, modified, size))
			if _, cached := valid[idHash]; cached {
				valid[idHash] = true
			}
		}
	}
	if rows.Err() != nil {
		rows.Close()
		return
	}
	rows.Close()

	l.cacheMu.Lock()
	newest := make(map[[16]byte][32]byte)
	keepUnknownVideo := make(map[[32]byte]bool)
	keepFileManager := make(map[[32]byte]bool)
	for key, entry := range l.cacheEntries {
		meta, ok := readThumbnailMeta(l.cache, formatThumbnailKeyHex(key))
		if ok && meta.Kind == "file-manager" {
			// File-manager thumbnails serve paths the gallery intentionally
			// does not index; they age out through the LRU only.
			keepFileManager[key] = true
			continue
		}
		if ok && meta.Kind == "video" {
			if !valid[entry.identityHash] {
				// Cinema also uses this shared bounded LRU. Its films may have
				// extensions the gallery intentionally does not index; retain
				// those entries until normal LRU eviction.
				keepUnknownVideo[key] = true
				continue
			}
		}
		if !valid[entry.identityHash] {
			continue
		}
		current, ok := newest[entry.identityHash]
		if !ok || entry.used.After(l.cacheEntries[current].used) ||
			(entry.used.Equal(l.cacheEntries[current].used) && bytes.Compare(key[:], current[:]) < 0) {
			newest[entry.identityHash] = key
		}
	}
	for key, entry := range l.cacheEntries {
		if keepUnknownVideo[key] || keepFileManager[key] {
			continue
		}
		if current, ok := newest[entry.identityHash]; ok && current == key {
			continue
		}
		_ = l.removeThumbnailEntryLocked(key, entry)
	}
	l.cacheMu.Unlock()
}

func (l *Library) nowTime() time.Time {
	if l.now != nil {
		return l.now()
	}
	return time.Now()
}

type ThumbnailCacheStats struct {
	UsedBytes  int64 `json:"usedBytes"`
	MaxBytes   int64 `json:"maxBytes"`
	EntryCount int   `json:"entryCount"`
	MaxEntries int   `json:"maxEntries"`
}

func (l *Library) CacheStats() ThumbnailCacheStats {
	l.cacheMu.Lock()
	defer l.cacheMu.Unlock()
	return ThumbnailCacheStats{
		UsedBytes:  l.cacheBytes,
		MaxBytes:   l.cacheLimit,
		EntryCount: len(l.cacheEntries),
		MaxEntries: l.thumbnailEntryLimit(),
	}
}

func (l *Library) ClearThumbnailCache() (int, int64, error) {
	if err := l.thumbMu.lock(l.ctx); err != nil {
		return 0, 0, err
	}
	defer l.thumbMu.unlock()
	l.faceMu.Lock()
	l.faceCache = map[string][]byte{}
	l.faceOrder = nil
	l.faceMu.Unlock()
	l.cleanupThumbnailTempFiles()
	l.cacheMu.Lock()
	defer l.cacheMu.Unlock()
	beforeBytes := l.cacheBytes
	removed := 0
	var lastErr error
	for key, entry := range l.cacheEntries {
		if err := l.removeThumbnailEntryLocked(key, entry); err != nil {
			lastErr = err
		} else {
			removed++
		}
	}
	freed := beforeBytes - l.cacheBytes
	if freed < 0 {
		freed = 0
	}
	if lastErr != nil {
		return removed, freed, thumbnailCacheError(lastErr)
	}
	return removed, freed, nil
}

// previewOutputBytes bounds a 2048px preview JPEG, which may legitimately be
// larger than a 512px list thumbnail.
const previewOutputBytes = mediaworker.MaxPreviewBytes
