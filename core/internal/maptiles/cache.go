package maptiles

import (
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
	s.diskEntries = map[string]diskTileEntry{}
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
		if ierr != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maxTileBytes {
			_ = os.Remove(filepath.Join(dir, entry.Name()))
			continue
		}
		id := strings.TrimSuffix(entry.Name(), ".tile")
		s.diskEntries[id] = diskTileEntry{size: info.Size(), used: info.ModTime()}
		s.diskBytes += info.Size()
	}
	s.evictDiskLocked("")
	return nil
}

func tileETag(data []byte) string {
	sum := sha256.Sum256(data)
	return `"` + hex.EncodeToString(sum[:16]) + `"`
}

func (s *Service) getCachedTile(tileID string) ([]byte, string, string, bool) {
	now := time.Now()
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
	_, onDisk := s.diskEntries[tileID]
	s.cacheMu.Unlock()

	if dir == "" || !onDisk {
		return nil, "", "", false
	}
	path := filepath.Join(dir, tileID+".tile")
	data, err := os.ReadFile(path)
	if err != nil || len(data) == 0 || len(data) > maxTileBytes {
		s.cacheMu.Lock()
		if old, ok := s.diskEntries[tileID]; ok {
			delete(s.diskEntries, tileID)
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
	if entry, ok := s.diskEntries[tileID]; ok {
		entry.used = now
		s.diskEntries[tileID] = entry
	}
	s.storeMemoryLocked(tileID, data, contentType, etag, now)
	s.cacheMu.Unlock()
	return data, contentType, etag, true
}

func (s *Service) putCachedTile(tileID string, data []byte, contentType string) string {
	now := time.Now()
	etag := tileETag(data)
	copied := append([]byte(nil), data...)
	s.cacheMu.Lock()
	s.storeMemoryLocked(tileID, copied, contentType, etag, now)
	dir := s.cacheDir
	s.cacheMu.Unlock()

	if dir != "" {
		tmp := filepath.Join(dir, tileID+".tmp")
		dst := filepath.Join(dir, tileID+".tile")
		if err := os.WriteFile(tmp, copied, 0600); err == nil {
			if err := os.Rename(tmp, dst); err == nil {
				s.cacheMu.Lock()
				if prev, ok := s.diskEntries[tileID]; ok {
					s.diskBytes -= prev.size
				}
				s.diskEntries[tileID] = diskTileEntry{size: int64(len(copied)), used: now}
				s.diskBytes += int64(len(copied))
				s.evictDiskLocked(tileID)
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

func (s *Service) evictDiskLocked(keepID string) {
	maxBytes := s.maxBytes
	if maxBytes <= 0 {
		maxBytes = DefaultMapTileCacheBytes
	}
	if s.diskBytes <= maxBytes && len(s.diskEntries) <= DefaultMapTileMaxEntries {
		return
	}
	type candidate struct {
		id    string
		entry diskTileEntry
	}
	victims := make([]candidate, 0, len(s.diskEntries))
	for id, entry := range s.diskEntries {
		if id != keepID {
			victims = append(victims, candidate{id, entry})
		}
	}
	sort.Slice(victims, func(i, j int) bool {
		return victims[i].entry.used.Before(victims[j].entry.used)
	})
	for _, v := range victims {
		if s.diskBytes <= maxBytes && len(s.diskEntries) <= DefaultMapTileMaxEntries {
			break
		}
		if s.cacheDir != "" {
			_ = os.Remove(filepath.Join(s.cacheDir, v.id+".tile"))
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
			_ = os.Remove(filepath.Join(s.cacheDir, id+".tile"))
		}
		s.diskEntries = map[string]diskTileEntry{}
		s.diskBytes = 0
	}
	return removed, freed
}
