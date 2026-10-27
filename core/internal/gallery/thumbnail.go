package gallery

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

const (
	// DefaultThumbnailCacheBytes is the disk budget used when the Mac App does
	// not pass an explicit setting. The budget bounds published JPEG bytes;
	// per-entry sidecars and short-lived worker files are fixed, small overhead
	// that is not accounted against it.
	DefaultThumbnailCacheBytes int64 = 1 << 30
	MinThumbnailCacheBytes     int64 = 256 << 20
	MaxThumbnailCacheBytes     int64 = 8 << 30
	// Small JPEGs must not create an unbounded heap index within a disk budget.
	MaxThumbnailCacheEntries = 50_000

	maxThumbnailSourceBytes = 64 << 20
	maxThumbnailOutputBytes = mediaworker.MaxThumbnailBytes
	thumbnailTempPrefix     = "tmp-"
	maxThumbnailMetaBytes   = 64 << 10
)

var ErrThumbnailCacheLimit = errors.New("thumbnail_cache_limit_out_of_range")

// removeThumbnailFile is replaceable so eviction accounting is testable when
// the filesystem refuses a delete.
var removeThumbnailFile = os.Remove

// afterThumbnailSourceCopy pauses a request between its private source copy and
// cache access so tests can run prune or mutate the index at that exact point.
// Production leaves it nil.
var afterThumbnailSourceCopy func(inputPath string)

// thumbnailTempName reports whether a cache-directory entry is a worker file
// that may be deleted once no request owns it.
func thumbnailTempName(name string) bool {
	return strings.HasPrefix(name, thumbnailTempPrefix) || strings.HasPrefix(name, "input-") || strings.HasPrefix(name, "thumb-")
}

type Options struct {
	ThumbnailCacheBytes int64
	// RootGeneration separates media identities when a registered root is
	// explicitly rebound, even if the replacement volume uses the same path.
	RootGeneration uint64
}

// thumbnailRenderer converts one private source copy into a JPEG at output.
// Production always uses the macOS system sips binary; tests inject a
// deterministic renderer instead of reimplementing image encoding.
type thumbnailRenderer interface {
	Render(ctx context.Context, inputPath, outputPath, sourceName string) error
	// RenderSized renders at the requested long-edge budget. Render keeps its
	// historical 512px meaning for the index-driven flow.
	RenderSized(ctx context.Context, inputPath, outputPath, sourceName string, maxPixel int) error
}

type sipsRenderer struct{}

func (sipsRenderer) Render(ctx context.Context, inputPath, outputPath, _ string) error {
	return sipsRenderer{}.RenderSized(ctx, inputPath, outputPath, "", 512)
}

func (sipsRenderer) RenderSized(ctx context.Context, inputPath, outputPath, _ string, maxPixel int) error {
	command := exec.CommandContext(ctx, "/usr/bin/sips", "-s", "format", "jpeg", "-Z", strconv.Itoa(maxPixel), inputPath, "--out", outputPath)
	return command.Run()
}

type photoThumbnailWorker interface {
	Thumbnail(context.Context, *os.File, string, string) (mediaworker.Metadata, error)
}

type workerThumbnailRenderer struct {
	worker   photoThumbnailWorker
	fallback thumbnailRenderer
}

func (r workerThumbnailRenderer) Render(ctx context.Context, inputPath, outputPath, sourceName string) error {
	return r.RenderSized(ctx, inputPath, outputPath, sourceName, 512)
}

func (r workerThumbnailRenderer) RenderSized(ctx context.Context, inputPath, outputPath, sourceName string, maxPixel int) error {
	input, err := os.Open(inputPath)
	if err != nil {
		return err
	}
	defer input.Close()
	// The worker creates its result with O_EXCL. This request owns the cache
	// temp placeholder and removes it immediately before dispatch.
	if err := os.Remove(outputPath); err != nil {
		return err
	}
	var workerErr error
	if maxPixel == 512 {
		_, workerErr = r.worker.Thumbnail(ctx, input, sourceName, outputPath)
	} else if sized, ok := r.worker.(sizedPhotoThumbnailWorker); ok {
		_, workerErr = sized.ThumbnailSized(ctx, input, sourceName, outputPath, maxPixel)
	} else {
		workerErr = mediaworker.ErrUnsupported
	}
	if errors.Is(workerErr, mediaworker.ErrUnavailable) || errors.Is(workerErr, mediaworker.ErrUnsupported) {
		_ = os.Remove(outputPath)
		return r.fallback.RenderSized(ctx, inputPath, outputPath, sourceName, maxPixel)
	}
	return workerErr
}

type sizedPhotoThumbnailWorker interface {
	ThumbnailSized(context.Context, *os.File, string, string, int) (mediaworker.Metadata, error)
}

type thumbnailGate struct{ token chan struct{} }

func newThumbnailGate() *thumbnailGate { return &thumbnailGate{token: make(chan struct{}, 1)} }

func (g *thumbnailGate) lock(ctx context.Context) error {
	if ctx == nil {
		ctx = context.Background()
	}
	select {
	case g.token <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (g *thumbnailGate) unlock() { <-g.token }

type thumbnailContextReader struct {
	ctx  context.Context
	read io.Reader
}

func (r thumbnailContextReader) Read(p []byte) (int, error) {
	select {
	case <-r.ctx.Done():
		return 0, r.ctx.Err()
	default:
		return r.read.Read(p)
	}
}

type thumbnailCacheEntry struct {
	size int64
	used time.Time
	// identity is the source version (share,path,mtime,size) this JPEG was
	// rendered from. It lets a clean scan prune stale cache keys even though the
	// filename itself is keyed by source content.
	identity string
}

// thumbnailMeta is the sidecar stored next to the JPEG. The cache filename is a
// SHA256 over the source content as well as its version, so the sidecar is the
// only way to relate a key back to an indexed asset during prune.
type thumbnailMeta struct {
	Share      string `json:"share"`
	Path       string `json:"path"`
	Modified   int64  `json:"modified"`
	Size       int64  `json:"size"`
	SourceHash string `json:"sourceHash"`
	Kind       string `json:"kind,omitempty"`
	// MaxPixel separates the 512px list thumbnail from the 2048px preview of
	// the same source inside the shared LRU.
	MaxPixel int `json:"maxPixel,omitempty"`
}

func (m thumbnailMeta) identity() string {
	return cacheID(m.Share, m.Path, m.Modified, m.Size)
}

func (m thumbnailMeta) key() string {
	return thumbnailKeySized(m.Share, m.Path, m.Modified, m.Size, m.SourceHash, m.MaxPixel)
}

// Thumbnail generates JPEG on first request, then serves it from a bounded
// LRU cache. Cache keys include a SHA256 of the source content, so a photo
// rewritten with the same size and mtime is still recognized as changed.
// The native worker uses ImageIO for orientation-aware JPEG generation; sips
// remains a fallback when the worker is unavailable or does not support a
// particular image type. Input is copied to a private temp file before either
// renderer sees it.
func (l *Library) Thumbnail(id int64) (*os.File, error) {
	return l.ThumbnailContext(l.ctx, id)
}

func (l *Library) ThumbnailContext(parent context.Context, id int64) (*os.File, error) {
	ctx, cancel := l.operationContext(parent)
	defer cancel()
	a, err := l.Asset(id)
	if err != nil {
		return nil, err
	}
	if a.Type != "photo" {
		return nil, errors.New("not_a_photo")
	}
	if a.Size > maxThumbnailSourceBytes {
		return nil, errors.New("photo_too_large_for_thumbnail")
	}
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	source, _, err := l.storage.Read(a.Path)
	if err != nil {
		return nil, err
	}
	defer source.Close()
	details, err := source.Stat()
	if err != nil {
		return nil, err
	}
	if !details.Mode().IsRegular() || details.Size() != a.Size || details.Size() > maxThumbnailSourceBytes {
		return nil, errors.New("asset_changed_rescan_required")
	}
	if err := os.MkdirAll(l.cache, 0700); err != nil {
		return nil, err
	}
	// A content hash is required even when mtime and size are unchanged.
	// Cache hits avoid copying the source into a private worker temp file.
	hasher := sha256.New()
	written, err := io.Copy(hasher, io.LimitReader(thumbnailContextReader{ctx: ctx, read: source}, maxThumbnailSourceBytes+1))
	if err != nil {
		return nil, err
	}
	if written != details.Size() || written > maxThumbnailSourceBytes {
		return nil, errors.New("asset_changed_rescan_required")
	}
	after, err := source.Stat()
	if err != nil || !after.Mode().IsRegular() || after.Size() != details.Size() || !after.ModTime().Equal(details.ModTime()) {
		return nil, errors.New("asset_changed_rescan_required")
	}
	sourceHash := hex.EncodeToString(hasher.Sum(nil))
	identity := cacheID(share, a.Path, details.ModTime().UnixNano(), details.Size())
	key := thumbnailKey(share, a.Path, details.ModTime().UnixNano(), details.Size(), sourceHash)
	// A scan can delete or rewrite the row while the source copy is in
	// progress. Cache entries are content-keyed, so without this check a hit
	// could still describe an asset the index no longer has.
	if err := l.verifyThumbnailAsset(id, share, a.Path, details.Size(), details.ModTime().UnixNano()); err != nil {
		return nil, err
	}
	if f, ok := l.cachedThumbnail(key, identity); ok {
		return f, nil
	}
	// Only a miss needs a private renderer input. Verify that the exact
	// copied bytes equal the content already hashed for the cache key.
	if _, err := source.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	tmp, err := l.createThumbnailTemp(thumbnailTempPrefix + "input-")
	if err != nil {
		return nil, err
	}
	inputName := tmp.Name()
	defer l.releaseThumbnailTemp(inputName)
	copyHash := sha256.New()
	copied, err := io.Copy(io.MultiWriter(tmp, copyHash), io.LimitReader(thumbnailContextReader{ctx: ctx, read: source}, maxThumbnailSourceBytes+1))
	cerr := tmp.Close()
	if err != nil {
		return nil, err
	}
	if cerr != nil {
		return nil, cerr
	}
	if copied != written || !bytes.Equal(copyHash.Sum(nil), hasher.Sum(nil)) {
		return nil, errors.New("asset_changed_rescan_required")
	}
	afterCopy, err := source.Stat()
	if err != nil || !afterCopy.Mode().IsRegular() || afterCopy.Size() != details.Size() || !afterCopy.ModTime().Equal(details.ModTime()) {
		return nil, errors.New("asset_changed_rescan_required")
	}
	if afterThumbnailSourceCopy != nil {
		afterThumbnailSourceCopy(inputName)
	}

	// Prune holds thumbMu while it deletes entries. Re-checking the asset row
	// under the same lock keeps a conversion from publishing a thumbnail for a
	// row removed by a clean scan.
	if err := l.thumbMu.lock(ctx); err != nil {
		return nil, err
	}
	defer l.thumbMu.unlock()
	if err := l.verifyThumbnailAsset(id, share, a.Path, details.Size(), details.ModTime().UnixNano()); err != nil {
		return nil, err
	}
	if f, ok := l.cachedThumbnail(key, identity); ok {
		return f, nil
	}
	output, err := l.createThumbnailTemp(thumbnailTempPrefix + "thumb-*.jpg")
	if err != nil {
		return nil, err
	}
	outName := output.Name()
	closed := output.Close()
	defer l.releaseThumbnailTemp(outName)
	if closed != nil {
		return nil, closed
	}
	renderCtx, renderCancel := context.WithTimeout(ctx, 20*time.Second)
	defer renderCancel()
	renderer := l.renderer
	if renderer == nil {
		fallback := sipsRenderer{}
		if worker, ok := l.worker.(photoThumbnailWorker); ok {
			renderer = workerThumbnailRenderer{worker: worker, fallback: fallback}
		} else {
			renderer = fallback
		}
	}
	if err := renderer.Render(renderCtx, inputName, outName, a.Name); err != nil {
		return nil, errors.New("thumbnail_conversion_failed")
	}
	stat, err := os.Stat(outName)
	if err != nil || !stat.Mode().IsRegular() || stat.Size() <= 0 || stat.Size() > maxThumbnailOutputBytes || validThumbnailPath(outName) != nil {
		return nil, errors.New("thumbnail_invalid")
	}
	// A single thumbnail larger than the whole budget cannot be tracked
	// without breaking the limit. Serve it from the private temp file and
	// leave the cache untouched instead of publishing an over-budget entry.
	if stat.Size() > l.cacheLimit {
		file, err := os.Open(outName)
		if err != nil {
			return nil, err
		}
		return file, nil
	}
	if err := l.verifyThumbnailAsset(id, share, a.Path, details.Size(), details.ModTime().UnixNano()); err != nil {
		return nil, err
	}
	meta := thumbnailMeta{
		Share:      share,
		Path:       a.Path,
		Modified:   details.ModTime().UnixNano(),
		Size:       details.Size(),
		SourceHash: sourceHash,
		Kind:       "photo",
	}
	if !l.prepareThumbnailCache(key) {
		return os.Open(outName)
	}
	if err := writeThumbnailMeta(l.cache, key, meta); err != nil {
		return nil, err
	}
	destination := filepath.Join(l.cache, key+".jpg")
	if err := os.Rename(outName, destination); err != nil {
		_ = removeThumbnailFile(thumbnailMetaPath(l.cache, key))
		return nil, err
	}
	if err := l.recordThumbnail(key, identity, stat.Size()); err != nil {
		// Eviction can fail after the JPEG has been published and indexed when
		// the filesystem refuses a delete. The new entry is still valid, so serve
		// it instead of reporting a failed request; startup and later evictions
		// retry the budget. Only an unopenable file makes this request fail.
		if file, openErr := os.Open(destination); openErr == nil {
			return file, nil
		}
		return nil, err
	}
	return os.Open(destination)
}

func thumbnailCacheError(err error) error {
	return fmt.Errorf("thumbnail_cache_error: %w", err)
}

// verifyThumbnailAsset re-reads the index row that produced size and modified.
// A request may call it without thumbMu to reject a cache hit after the row was
// removed or rewritten. The publication path calls it while holding thumbMu so
// a prune that already dropped the row cannot interleave with publication.
func (l *Library) verifyThumbnailAsset(id int64, share, assetPath string, size, modified int64) error {
	var path string
	var rowSize, rowModified int64
	err := l.db.QueryRow("SELECT path,size,modified FROM assets WHERE share=? AND id=?", share, id).
		Scan(&path, &rowSize, &rowModified)
	if errors.Is(err, sql.ErrNoRows) {
		return errors.New("asset_changed_rescan_required")
	}
	if err != nil {
		return err
	}
	if path != assetPath || rowSize != size || rowModified != modified {
		return errors.New("asset_changed_rescan_required")
	}
	return nil
}

func thumbnailKey(share, path string, modified, size int64, sourceHash string) string {
	return thumbnailKeySized(share, path, modified, size, sourceHash, 0)
}

func thumbnailKeySized(share, path string, modified, size int64, sourceHash string, maxPixel int) string {
	formatVersion := "thumbnail-v2-orientation"
	if maxPixel > 0 {
		formatVersion += fmt.Sprintf("|px:%d", maxPixel)
	}
	raw := formatVersion + "|" + share + "|" + path + "|" + strconv.FormatInt(modified, 10) + "|" + strconv.FormatInt(size, 10) + "|" + sourceHash
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

func thumbnailMetaPath(cache, key string) string {
	return filepath.Join(cache, key+".meta")
}

func writeThumbnailMeta(cache, key string, meta thumbnailMeta) error {
	data, err := json.Marshal(meta)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(cache, thumbnailTempPrefix+"meta-")
	if err != nil {
		return err
	}
	name := tmp.Name()
	_, writeErr := tmp.Write(data)
	closeErr := tmp.Close()
	if writeErr != nil {
		_ = removeThumbnailFile(name)
		return writeErr
	}
	if closeErr != nil {
		_ = removeThumbnailFile(name)
		return closeErr
	}
	if err := os.Rename(name, thumbnailMetaPath(cache, key)); err != nil {
		_ = removeThumbnailFile(name)
		return err
	}
	return nil
}

func readThumbnailMeta(cache, key string) (thumbnailMeta, bool) {
	file, err := os.Open(thumbnailMetaPath(cache, key))
	if err != nil {
		return thumbnailMeta{}, false
	}
	defer file.Close()
	// Sidecars contain a path and a few scalar fields. Corrupt/private-cache
	// files must not turn an index rebuild into an unbounded ReadFile.
	data, err := io.ReadAll(io.LimitReader(file, maxThumbnailMetaBytes+1))
	if err != nil || len(data) > maxThumbnailMetaBytes {
		return thumbnailMeta{}, false
	}
	var meta thumbnailMeta
	if err := json.Unmarshal(data, &meta); err != nil {
		return thumbnailMeta{}, false
	}
	if meta.SourceHash == "" || meta.key() != key {
		return thumbnailMeta{}, false
	}
	return meta, true
}

// validThumbnailPath checks the size and JPEG envelope. Empty, oversized and
// truncated/non-JPEG files are treated as corrupt cache and rebuilt.
func validThumbnailPath(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return errors.New("thumbnail_cache_entry_invalid")
	}
	return validateThumbnailFile(file, info.Size())
}

func validateThumbnailFile(file *os.File, size int64) error {
	if size <= 0 || size > maxThumbnailOutputBytes || size < 5 {
		return errors.New("thumbnail_cache_entry_invalid")
	}
	var header [3]byte
	if _, err := file.ReadAt(header[:], 0); err != nil {
		return errors.New("thumbnail_cache_entry_invalid")
	}
	if header[0] != 0xFF || header[1] != 0xD8 || header[2] != 0xFF {
		return errors.New("thumbnail_cache_entry_invalid")
	}
	var footer [2]byte
	if _, err := file.ReadAt(footer[:], size-2); err != nil {
		return errors.New("thumbnail_cache_entry_invalid")
	}
	if footer[0] != 0xFF || footer[1] != 0xD9 {
		return errors.New("thumbnail_cache_entry_invalid")
	}
	return nil
}

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
	l.cacheEntries = map[string]thumbnailCacheEntry{}
	l.cacheBytes = 0
	if err := l.walkThumbnailDirectory(func(entry os.DirEntry) error {
		if entry.IsDir() {
			return nil
		}
		key, ok := thumbnailCacheKey(entry.Name())
		if !ok {
			return nil
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() || validThumbnailPath(filepath.Join(l.cache, entry.Name())) != nil {
			if err := removeThumbnailCacheFiles(l.cache, key); err != nil {
				return thumbnailCacheError(err)
			}
			return nil
		}
		meta, ok := readThumbnailMeta(l.cache, key)
		if !ok {
			if err := removeThumbnailCacheFiles(l.cache, key); err != nil {
				return thumbnailCacheError(err)
			}
			return nil
		}
		l.cacheEntries[key] = thumbnailCacheEntry{size: info.Size(), used: info.ModTime(), identity: meta.identity()}
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
		key := strings.TrimSuffix(entry.Name(), ".meta")
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

func (l *Library) cachedThumbnail(key, identity string) (*os.File, bool) {
	destination := filepath.Join(l.cache, key+".jpg")
	l.cacheMu.Lock()
	entry, ok := l.cacheEntries[key]
	if !ok {
		l.cacheMu.Unlock()
		return nil, false
	}
	if entry.identity != identity {
		l.removeThumbnailEntryLocked(key, entry)
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
		l.removeThumbnailEntryLocked(key, entry)
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

func (l *Library) recordThumbnail(key, identity string, size int64) error {
	used := l.nowTime()
	l.cacheMu.Lock()
	defer l.cacheMu.Unlock()
	if previous, ok := l.cacheEntries[key]; ok {
		l.cacheBytes -= previous.size
	}
	// A content replacement keeps the same asset identity but gets a new key.
	// Drop older renders of that identity so at most one version is retained.
	for other, entry := range l.cacheEntries {
		if other != key && entry.identity == identity {
			_ = l.removeThumbnailEntryLocked(other, entry)
		}
	}
	l.cacheEntries[key] = thumbnailCacheEntry{size: size, used: used, identity: identity}
	l.cacheBytes += size
	_ = os.Chtimes(filepath.Join(l.cache, key+".jpg"), used, used)
	return l.evictThumbnailsLocked(key)
}

// removeThumbnailEntryLocked deletes the JPEG and its sidecar and updates the
// accounting. The entry remains indexed and counted when the filesystem refuses
// the delete, so the budget still reflects bytes present on disk.
func (l *Library) removeThumbnailEntryLocked(key string, entry thumbnailCacheEntry) error {
	err := removeThumbnailFile(filepath.Join(l.cache, key+".jpg"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	_ = removeThumbnailFile(thumbnailMetaPath(l.cache, key))
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
func (l *Library) prepareThumbnailCache(key string) bool {
	l.cacheMu.Lock()
	defer l.cacheMu.Unlock()
	limit := l.thumbnailEntryLimit()
	if _, exists := l.cacheEntries[key]; exists || len(l.cacheEntries) < limit {
		return true
	}
	_ = l.evictThumbnailsToLocked("", limit-1)
	return len(l.cacheEntries) < limit
}

func (l *Library) evictThumbnailsLocked(keepKey string) error {
	return l.evictThumbnailsToLocked(keepKey, l.thumbnailEntryLimit())
}

func (l *Library) evictThumbnailsToLocked(keepKey string, limit int) error {
	if l.cacheBytes <= l.cacheLimit && len(l.cacheEntries) <= limit {
		return nil
	}
	type candidate struct {
		key   string
		entry thumbnailCacheEntry
	}
	victims := make([]candidate, 0, len(l.cacheEntries))
	for key, entry := range l.cacheEntries {
		if key != keepKey {
			victims = append(victims, candidate{key, entry})
		}
	}
	// Sort once rather than scanning the whole map for every evicted entry.
	sort.Slice(victims, func(i, j int) bool {
		if victims[i].entry.used.Equal(victims[j].entry.used) {
			return victims[i].key < victims[j].key
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
	valid := make(map[string]bool, len(l.cacheEntries))
	for _, entry := range l.cacheEntries {
		valid[entry.identity] = false
	}
	l.cacheMu.Unlock()
	rows, err := l.db.Query("SELECT path,modified,size FROM assets WHERE share=?", share)
	if err != nil {
		return
	}
	for rows.Next() {
		var path string
		var modified, size int64
		if rows.Scan(&path, &modified, &size) == nil {
			identity := cacheID(share, path, modified, size)
			if _, cached := valid[identity]; cached {
				valid[identity] = true
			}
		}
	}
	if rows.Err() != nil {
		rows.Close()
		return
	}
	rows.Close()

	l.cacheMu.Lock()
	newest := make(map[string]string)
	keepUnknownVideo := make(map[string]bool)
	keepFileManager := make(map[string]bool)
	for key, entry := range l.cacheEntries {
		meta, ok := readThumbnailMeta(l.cache, key)
		if ok && meta.Kind == "file-manager" {
			// File-manager thumbnails serve paths the gallery intentionally
			// does not index; they age out through the LRU only.
			keepFileManager[key] = true
			continue
		}
		if ok && meta.Kind == "video" {
			if !valid[entry.identity] {
				// Cinema also uses this shared bounded LRU. Its films may have
				// extensions the gallery intentionally does not index; retain
				// those entries until normal LRU eviction.
				keepUnknownVideo[key] = true
				continue
			}
		}
		if !valid[entry.identity] {
			continue
		}
		current, ok := newest[entry.identity]
		if !ok || entry.used.After(l.cacheEntries[current].used) || (entry.used.Equal(l.cacheEntries[current].used) && key < current) {
			newest[entry.identity] = key
		}
	}
	for key, entry := range l.cacheEntries {
		if keepUnknownVideo[key] || keepFileManager[key] {
			continue
		}
		if current, ok := newest[entry.identity]; ok && current == key {
			continue
		}
		l.removeThumbnailEntryLocked(key, entry)
	}
	l.cacheMu.Unlock()
}

func (l *Library) nowTime() time.Time {
	if l.now != nil {
		return l.now()
	}
	return time.Now()
}

// previewOutputBytes bounds a 2048px preview JPEG, which may legitimately be
// larger than a 512px list thumbnail.
const previewOutputBytes = mediaworker.MaxPreviewBytes
