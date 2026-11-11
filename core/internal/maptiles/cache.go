package maptiles

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	DefaultMapTileCacheBytes = 256 * 1024 * 1024
	DefaultMapTileMaxEntries = 15000
	memoryTileCacheBytes     = 32 * 1024 * 1024
	memoryTileMaxEntries     = 1000
)

type TileCacheStats struct {
	UsedBytes  int64 `json:"usedBytes"`
	MaxBytes   int64 `json:"maxBytes"`
	EntryCount int   `json:"entryCount"`
	MaxEntries int   `json:"maxEntries"`
}

type cachedTile struct {
	data        []byte
	contentType string
	etag        string
	used        time.Time
}

type diskTileEntry struct {
	size int64
	used time.Time
}

func diskKeyForTileID(tileID string) [32]byte {
	return sha256.Sum256([]byte(tileID))
}

func parseDiskTileKeyHex(name string) ([32]byte, bool) {
	var key [32]byte
	if len(name) != 64 {
		return key, false
	}
	n, err := hex.Decode(key[:], []byte(name))
	if err != nil || n != 32 {
		return key, false
	}
	return key, true
}

func formatDiskTileKeyHex(key [32]byte) string {
	return hex.EncodeToString(key[:])
}

func (s *Service) ConfigureDiskCache(dir string, maxBytes int64) error {
	if dir == "" {
		return nil
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	if maxBytes <= 0 {
		maxBytes = DefaultMapTileCacheBytes
	}
	s.cacheMu.Lock()
	defer s.cacheMu.Unlock()
	s.cacheDir = dir
	s.maxBytes = maxBytes
	s.diskEntries = map[[32]byte]diskTileEntry{}
	s.diskBytes = 0
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".tile") {
			continue
		}
		info, ierr := entry.Info()
		id := strings.TrimSuffix(entry.Name(), ".tile")
		key, validKey := parseDiskTileKeyHex(id)
		if !validKey || ierr != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maxTileBytes {
			_ = os.Remove(filepath.Join(dir, entry.Name()))
			continue
		}
		s.diskEntries[key] = diskTileEntry{size: info.Size(), used: info.ModTime()}
		s.diskBytes += info.Size()
	}
	s.evictDiskLocked(nil)
	return nil
}

func tileETag(data []byte) string {
	sum := sha256.Sum256(data)
	return `"` + hex.EncodeToString(sum[:16]) + `"`
}

func (s *Service) getCachedTile(tileID string) ([]byte, string, string, bool) {
	now := time.Now()
	diskKey := diskKeyForTileID(tileID)
	s.cacheMu.Lock()
	if s.memEntries != nil {
		if item, ok := s.memEntries[tileID]; ok {
			item.used = now
			s.memEntries[tileID] = item
			s.cacheMu.Unlock()
			return item.data, item.contentType, item.etag, true
		}
	}
	dir := s.cacheDir
	_, onDisk := s.diskEntries[diskKey]
	s.cacheMu.Unlock()

	if dir == "" || !onDisk {
		return nil, "", "", false
	}
	path := filepath.Join(dir, formatDiskTileKeyHex(diskKey)+".tile")
	data, err := os.ReadFile(path)
	if err != nil || len(data) == 0 || len(data) > maxTileBytes {
		s.cacheMu.Lock()
		if old, ok := s.diskEntries[diskKey]; ok {
			delete(s.diskEntries, diskKey)
			s.diskBytes -= old.size
			if s.diskBytes < 0 {
				s.diskBytes = 0
			}
		}
		s.cacheMu.Unlock()
		_ = os.Remove(path)
		return nil, "", "", false
	}
	contentType := http.DetectContentType(data)
	if !strings.HasPrefix(contentType, "image/") {
		_ = os.Remove(path)
		return nil, "", "", false
	}
	etag := tileETag(data)
	s.cacheMu.Lock()
	if entry, ok := s.diskEntries[diskKey]; ok {
		entry.used = now
		s.diskEntries[diskKey] = entry
	}
	s.storeMemoryLocked(tileID, data, contentType, etag, now)
	s.cacheMu.Unlock()
	return data, contentType, etag, true
}

// putCachedTile stores a freshly read tile slice directly in memory and disk
// without making a second heap copy of the image bytes.
func (s *Service) putCachedTile(tileID string, data []byte, contentType string) string {
	now := time.Now()
	etag := tileETag(data)
	stored := data[:len(data):len(data)]
	diskKey := diskKeyForTileID(tileID)
	s.cacheMu.Lock()
	s.storeMemoryLocked(tileID, stored, contentType, etag, now)
	dir := s.cacheDir
	s.cacheMu.Unlock()

	if dir != "" {
		hexID := formatDiskTileKeyHex(diskKey)
		tmp := filepath.Join(dir, hexID+".tmp")
		dst := filepath.Join(dir, hexID+".tile")
		if err := os.WriteFile(tmp, stored, 0600); err == nil {
			if err := os.Rename(tmp, dst); err == nil {
				s.cacheMu.Lock()
				if prev, ok := s.diskEntries[diskKey]; ok {
					s.diskBytes -= prev.size
				}
				s.diskEntries[diskKey] = diskTileEntry{size: int64(len(stored)), used: now}
				s.diskBytes += int64(len(stored))
				s.evictDiskLocked(&diskKey)
				s.cacheMu.Unlock()
			} else {
				_ = os.Remove(tmp)
			}
		}
	}
	return etag
}

func (s *Service) storeMemoryLocked(tileID string, data []byte, contentType, etag string, now time.Time) {
	if s.memEntries == nil {
		s.memEntries = map[string]cachedTile{}
	}
	if prev, ok := s.memEntries[tileID]; ok {
		s.memBytes -= int64(len(prev.data))
	}
	s.memEntries[tileID] = cachedTile{
		data:        data,
		contentType: contentType,
		etag:        etag,
		used:        now,
	}
	s.memBytes += int64(len(data))
	for len(s.memEntries) > memoryTileMaxEntries || s.memBytes > memoryTileCacheBytes {
		var oldestKey string
		var oldestTime time.Time
		for k, v := range s.memEntries {
			if k == tileID {
				continue
			}
			if oldestKey == "" || v.used.Before(oldestTime) {
				oldestKey = k
				oldestTime = v.used
			}
		}
		if oldestKey == "" {
			break
		}
		victim := s.memEntries[oldestKey]
		delete(s.memEntries, oldestKey)
		s.memBytes -= int64(len(victim.data))
	}
}

func (s *Service) evictDiskLocked(keepKey *[32]byte) {
	maxBytes := s.maxBytes
	if maxBytes <= 0 {
		maxBytes = DefaultMapTileCacheBytes
	}
	if s.diskBytes <= maxBytes && len(s.diskEntries) <= DefaultMapTileMaxEntries {
		return
	}
	type candidate struct {
		id    [32]byte
		entry diskTileEntry
	}
	victims := make([]candidate, 0, len(s.diskEntries))
	for id, entry := range s.diskEntries {
		if keepKey == nil || id != *keepKey {
			victims = append(victims, candidate{id, entry})
		}
	}
	sort.Slice(victims, func(i, j int) bool {
		if victims[i].entry.used.Equal(victims[j].entry.used) {
			return bytes.Compare(victims[i].id[:], victims[j].id[:]) < 0
		}
		return victims[i].entry.used.Before(victims[j].entry.used)
	})
	for _, v := range victims {
		if s.diskBytes <= maxBytes && len(s.diskEntries) <= DefaultMapTileMaxEntries {
			break
		}
		if s.cacheDir != "" {
			_ = os.Remove(filepath.Join(s.cacheDir, formatDiskTileKeyHex(v.id)+".tile"))
		}
		delete(s.diskEntries, v.id)
		s.diskBytes -= v.entry.size
		if s.diskBytes < 0 {
			s.diskBytes = 0
		}
	}
}

func (s *Service) CacheStats() TileCacheStats {
	s.cacheMu.Lock()
	defer s.cacheMu.Unlock()
	maxBytes := s.maxBytes
	if maxBytes <= 0 {
		maxBytes = DefaultMapTileCacheBytes
	}
	if s.cacheDir != "" {
		return TileCacheStats{
			UsedBytes:  s.diskBytes,
			MaxBytes:   maxBytes,
			EntryCount: len(s.diskEntries),
			MaxEntries: DefaultMapTileMaxEntries,
		}
	}
	return TileCacheStats{
		UsedBytes:  s.memBytes,
		MaxBytes:   memoryTileCacheBytes,
		EntryCount: len(s.memEntries),
		MaxEntries: memoryTileMaxEntries,
	}
}

func (s *Service) ClearCache() (int, int64) {
	s.cacheMu.Lock()
	defer s.cacheMu.Unlock()
	removed := len(s.memEntries)
	freed := s.memBytes
	s.memEntries = map[string]cachedTile{}
	s.memBytes = 0
	if s.cacheDir != "" {
		removed = len(s.diskEntries)
		freed = s.diskBytes
		for id := range s.diskEntries {
			_ = os.Remove(filepath.Join(s.cacheDir, formatDiskTileKeyHex(id)+".tile"))
		}
		s.diskEntries = map[[32]byte]diskTileEntry{}
		s.diskBytes = 0
	}
	return removed, freed
}
