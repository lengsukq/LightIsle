package server

import (
	"crypto/subtle"
	"encoding/hex"
	"sync"
	"time"
)

const (
	collectGrantCookie     = "lightisle_collect_grant"
	collectUploadChunkHint = int64(4) << 20 // 4 MiB recommended chunk size
	collectUploadMaxInMem  = 4096
	collectUploadStaleTTL  = 30 * time.Minute
)

type trackedCollectUpload struct {
	linkDigestHex string
	size          int64
	lastActiveAt  time.Time
}

type collectUploadTracker struct {
	mu      sync.Mutex
	uploads map[string]trackedCollectUpload
}

func newCollectUploadTracker() *collectUploadTracker {
	return &collectUploadTracker{uploads: make(map[string]trackedCollectUpload)}
}

func (t *collectUploadTracker) gcLocked(now time.Time) {
	for id, u := range t.uploads {
		if now.Sub(u.lastActiveAt) > collectUploadStaleTTL {
			delete(t.uploads, id)
		}
	}
}

func (t *collectUploadTracker) tryRegister(uploadID string, linkDigest []byte, size int64, maxFiles int, maxTotalBytes int64, uploadedFiles int, uploadedBytes int64) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := time.Now()
	t.gcLocked(now)
	if len(t.uploads) >= collectUploadMaxInMem {
		return false
	}
	key := hex.EncodeToString(linkDigest)
	var inflightFiles int
	var inflightBytes int64
	for _, u := range t.uploads {
		if u.linkDigestHex == key {
			inflightFiles++
			inflightBytes += u.size
		}
	}
	if maxFiles > 0 && uploadedFiles+inflightFiles >= maxFiles {
		return false
	}
	if maxTotalBytes > 0 && uploadedBytes+inflightBytes+size > maxTotalBytes {
		return false
	}
	t.uploads[uploadID] = trackedCollectUpload{
		linkDigestHex: key,
		size:          size,
		lastActiveAt:  now,
	}
	return true
}

func (t *collectUploadTracker) matches(uploadID string, linkDigest []byte) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := time.Now()
	t.gcLocked(now)
	u, ok := t.uploads[uploadID]
	if !ok {
		return false
	}
	expected := hex.EncodeToString(linkDigest)
	if subtle.ConstantTimeCompare([]byte(u.linkDigestHex), []byte(expected)) != 1 {
		return false
	}
	u.lastActiveAt = now
	t.uploads[uploadID] = u
	return true
}

func (t *collectUploadTracker) remove(uploadID string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.uploads, uploadID)
}

func (t *collectUploadTracker) inflightFor(linkDigest []byte) (int, int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.gcLocked(time.Now())
	key := hex.EncodeToString(linkDigest)
	var count int
	var bytes int64
	for _, u := range t.uploads {
		if u.linkDigestHex == key {
			count++
			bytes += u.size
		}
	}
	return count, bytes
}
