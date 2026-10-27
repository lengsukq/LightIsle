package gallery

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Thumbnail sizes served by the file-manager endpoint. 512px backs list
// tiles; 2048px backs the photo viewer and HEIC preview.
const (
	ThumbnailSizeList    = 512
	ThumbnailSizePreview = 2048
)

var thumbnailPhotoExtensions = map[string]bool{
	".jpg": true, ".jpeg": true, ".png": true, ".gif": true, ".webp": true,
	".heic": true, ".heif": true,
}

var thumbnailVideoExtensions = map[string]bool{
	".mp4": true, ".mov": true, ".m4v": true,
}

// ThumbnailSizeSupported normalizes the client-supplied size parameter; an
// unsupported value disables the endpoint for that request.
func ThumbnailSizeSupported(size int) bool {
	return size == ThumbnailSizeList || size == ThumbnailSizePreview
}

// ThumbnailPathSupported reports whether the extension has a thumbnail
// pipeline. The HTTP layer uses it to answer 404 before opening anything.
func ThumbnailPathSupported(name string) bool {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif",
		".mp4", ".mov", ".m4v":
		return true
	}
	return false
}

// ThumbnailFromPathContext renders a JPEG for any authorized path inside the
// shared root — not only indexed gallery assets — using the same bounded LRU
// cache. Entries are marked "file-manager" so a clean gallery scan never
// prunes them; they age out through the LRU budget like every other entry.
// Videos reuse the poster pipeline (fixed size); photos render at the
// requested long edge with the native worker, falling back to sips.
func (l *Library) ThumbnailFromPathContext(parent context.Context, relPath string, maxPixel int) (*os.File, error) {
	if !ThumbnailSizeSupported(maxPixel) {
		return nil, errors.New("invalid_thumbnail_size")
	}
	ctx, cancel := l.operationContext(parent)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if !ThumbnailPathSupported(relPath) {
		return nil, errors.New("thumbnail_unsupported")
	}
	ext := strings.ToLower(filepath.Ext(relPath))
	if thumbnailVideoExtensions[ext] {
		return l.videoThumbnailFromPath(ctx, relPath)
	}
	return l.photoThumbnailFromPath(ctx, relPath, maxPixel)
}

func (l *Library) videoThumbnailFromPath(ctx context.Context, relPath string) (*os.File, error) {
	source, info, err := l.storage.Read(relPath)
	if err != nil {
		return nil, err
	}
	defer source.Close()
	if !info.Mode().IsRegular() {
		return nil, errors.New("thumbnail_unsupported")
	}
	// VideoThumbnailFromFileContext validates the source identity itself and
	// shares the same LRU budget; its posters have a fixed worker size.
	return l.VideoThumbnailFromFileContext(ctx, relPath, source, info)
}

func (l *Library) photoThumbnailFromPath(ctx context.Context, relPath string, maxPixel int) (*os.File, error) {
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	source, details, err := l.storage.Read(relPath)
	if err != nil {
		return nil, err
	}
	defer source.Close()
	if !details.Mode().IsRegular() || details.Size() <= 0 || details.Size() > maxThumbnailSourceBytes {
		return nil, errors.New("photo_too_large_for_thumbnail")
	}
	if err := os.MkdirAll(l.cache, 0700); err != nil {
		return nil, err
	}
	hasher := sha256.New()
	written, err := io.Copy(hasher, io.LimitReader(thumbnailContextReader{ctx: ctx, read: source}, maxThumbnailSourceBytes+1))
	if err != nil {
		return nil, err
	}
	if written != details.Size() {
		return nil, ErrAssetChanged
	}
	after, err := source.Stat()
	if err != nil || !after.Mode().IsRegular() || after.Size() != details.Size() || !after.ModTime().Equal(details.ModTime()) {
		return nil, ErrAssetChanged
	}
	sourceHash := hex.EncodeToString(hasher.Sum(nil))
	identity := cacheID(share, relPath, details.ModTime().UnixNano(), details.Size())
	key := thumbnailKeySized(share, relPath, details.ModTime().UnixNano(), details.Size(), sourceHash, maxPixel)
	if f, ok := l.cachedThumbnail(key, identity); ok {
		return f, nil
	}
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
		return nil, ErrAssetChanged
	}
	afterCopy, err := source.Stat()
	if err != nil || !afterCopy.Mode().IsRegular() || afterCopy.Size() != details.Size() || !afterCopy.ModTime().Equal(details.ModTime()) {
		return nil, ErrAssetChanged
	}

	if err := l.thumbMu.lock(ctx); err != nil {
		return nil, err
	}
	defer l.thumbMu.unlock()
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
	renderCtx, renderCancel := context.WithTimeout(ctx, 30*time.Second)
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
	if err := renderer.RenderSized(renderCtx, inputName, outName, filepath.Base(relPath), maxPixel); err != nil {
		return nil, errors.New("thumbnail_conversion_failed")
	}
	byteCap := int64(maxThumbnailOutputBytes)
	if maxPixel > ThumbnailSizeList {
		byteCap = int64(previewOutputBytes)
	}
	stat, err := os.Stat(outName)
	if err != nil || !stat.Mode().IsRegular() || stat.Size() <= 0 || stat.Size() > byteCap || validThumbnailPath(outName) != nil {
		return nil, errors.New("thumbnail_invalid")
	}
	if stat.Size() > l.cacheLimit {
		file, err := os.Open(outName)
		if err != nil {
			return nil, err
		}
		return file, nil
	}
	meta := thumbnailMeta{
		Share:      share,
		Path:       relPath,
		Modified:   details.ModTime().UnixNano(),
		Size:       details.Size(),
		SourceHash: sourceHash,
		Kind:       "file-manager",
		MaxPixel:   maxPixel,
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
		if file, openErr := os.Open(destination); openErr == nil {
			return file, nil
		}
		return nil, err
	}
	return os.Open(destination)
}
