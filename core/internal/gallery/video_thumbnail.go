package gallery

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"time"

	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

const videoFingerprintSampleBytes int64 = 64 << 10

func (l *Library) VideoThumbnail(id int64) (*os.File, error) {
	return l.VideoThumbnailContext(l.ctx, id)
}

func (l *Library) VideoThumbnailContext(parent context.Context, id int64) (*os.File, error) {
	ctx, cancel := l.operationContext(parent)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	asset, err := l.Asset(id)
	if err != nil {
		return nil, err
	}
	if asset.Type != "video" {
		return nil, errors.New("not_a_video")
	}
	share, err := l.share()
	if err != nil {
		return nil, err
	}
	if err := l.verifyThumbnailAsset(id, share, asset.Path, asset.Size, asset.Modified); err != nil {
		return nil, err
	}
	source, info, err := l.storage.Read(asset.Path)
	if err != nil {
		return nil, err
	}
	defer source.Close()
	if info.Size() != asset.Size || info.ModTime().UnixNano() != asset.Modified {
		return nil, ErrAssetChanged
	}
	poster, err := l.VideoThumbnailFromFileContext(ctx, asset.Path, source, info)
	if err != nil {
		return nil, err
	}
	if err := l.verifyThumbnailAsset(id, share, asset.Path, asset.Size, asset.Modified); err != nil {
		poster.Close()
		return nil, err
	}
	return poster, nil
}

// VideoThumbnailFromFile generates a poster from a caller-owned, securely
// opened file descriptor. The worker receives that descriptor as fd 3; the
// movie is never reopened by its shared-folder path or copied into cache.
// Poster JPEGs use the gallery thumbnail cache and its existing LRU budget.
func (l *Library) VideoThumbnailFromFile(assetPath string, source *os.File, expected os.FileInfo) (*os.File, error) {
	return l.VideoThumbnailFromFileContext(l.ctx, assetPath, source, expected)
}

func (l *Library) VideoThumbnailFromFileContext(parent context.Context, assetPath string, source *os.File, expected os.FileInfo) (*os.File, error) {
	ctx, cancel := l.operationContext(parent)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if source == nil || expected == nil || !expected.Mode().IsRegular() {
		return nil, errors.New("invalid_video_source")
	}
	if l.worker == nil {
		return nil, mediaworker.ErrUnavailable
	}
	share, online := l.storage.State()
	if !online {
		return nil, ErrUnavailable
	}
	before, err := source.Stat()
	if err != nil || !before.Mode().IsRegular() || before.Size() != expected.Size() || !before.ModTime().Equal(expected.ModTime()) {
		return nil, ErrAssetChanged
	}
	fingerprint, err := videoFingerprint(source, before)
	if err != nil {
		return nil, err
	}
	identity := cacheID(share, assetPath, before.ModTime().UnixNano(), before.Size())
	key := thumbnailKey(share, assetPath, before.ModTime().UnixNano(), before.Size(), fingerprint)
	if err := l.verifyCurrentVideoSource(ctx, share, assetPath, before, fingerprint); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(l.cache, 0700); err != nil {
		return nil, err
	}
	if file, ok := l.cachedThumbnail(key, identity); ok {
		return file, nil
	}

	if err := l.thumbMu.lock(ctx); err != nil {
		return nil, err
	}
	defer l.thumbMu.unlock()
	if err := l.verifyCurrentVideoSource(ctx, share, assetPath, before, fingerprint); err != nil {
		return nil, err
	}
	if file, ok := l.cachedThumbnail(key, identity); ok {
		return file, nil
	}
	// The native worker validates the output extension before it creates the
	// file, so retain a .jpg suffix while still registering the private temp.
	output, err := l.createThumbnailTemp(thumbnailTempPrefix + "thumb-*.jpg")
	if err != nil {
		return nil, err
	}
	outputPath := output.Name()
	if err := output.Close(); err != nil {
		l.releaseThumbnailTemp(outputPath)
		return nil, err
	}
	defer l.releaseThumbnailTemp(outputPath)
	// The native worker creates its output with O_EXCL|O_NOFOLLOW. Keep the
	// path registered as a private in-flight temp, but remove CreateTemp's
	// placeholder so the worker can atomically claim that exact path.
	if err := os.Remove(outputPath); err != nil {
		return nil, err
	}
	workerCtx, workerCancel := context.WithTimeout(ctx, 25*time.Second)
	defer workerCancel()
	metadata, err := l.worker.Poster(workerCtx, source, filepath.Base(assetPath), outputPath)
	if err != nil {
		return nil, err
	}
	if metadata.Status != "ok" || metadata.Kind != "video" || metadata.Width < 1 || metadata.Height < 1 {
		return nil, mediaworker.ErrInvalidResponse
	}
	after, err := source.Stat()
	if err != nil || !after.Mode().IsRegular() || after.Size() != before.Size() || !after.ModTime().Equal(before.ModTime()) {
		return nil, ErrAssetChanged
	}
	if err := l.verifyCurrentVideoSource(ctx, share, assetPath, after, fingerprint); err != nil {
		return nil, err
	}
	info, err := os.Lstat(outputPath)
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maxThumbnailOutputBytes || validThumbnailPath(outputPath) != nil {
		return nil, errors.New("thumbnail_invalid")
	}
	if info.Size() > l.cacheLimit {
		return os.Open(outputPath)
	}
	meta := thumbnailMeta{
		Share: share, Path: assetPath, Modified: before.ModTime().UnixNano(),
		Size: before.Size(), SourceHash: fingerprint, Kind: "video",
	}
	if err := writeThumbnailMeta(l.cache, key, meta); err != nil {
		return nil, err
	}
	destination := filepath.Join(l.cache, key+".jpg")
	if err := os.Rename(outputPath, destination); err != nil {
		_ = removeThumbnailFile(thumbnailMetaPath(l.cache, key))
		return nil, err
	}
	if err := l.recordThumbnail(key, identity, info.Size()); err != nil {
		if file, openErr := os.Open(destination); openErr == nil {
			return file, nil
		}
		return nil, err
	}
	return os.Open(destination)
}

func (l *Library) verifyCurrentVideoSource(ctx context.Context, share, assetPath string, opened os.FileInfo, fingerprint string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	currentShare, online := l.storage.State()
	if !online || currentShare != share {
		return ErrAssetChanged
	}
	current, _, err := l.storage.Read(assetPath)
	if err != nil {
		return ErrAssetChanged
	}
	defer current.Close()
	currentInfo, err := current.Stat()
	if err != nil || !os.SameFile(opened, currentInfo) || currentInfo.Size() != opened.Size() || !currentInfo.ModTime().Equal(opened.ModTime()) {
		return ErrAssetChanged
	}
	currentFingerprint, err := videoFingerprint(current, currentInfo)
	if err != nil || currentFingerprint != fingerprint {
		return ErrAssetChanged
	}
	currentShare, online = l.storage.State()
	if !online || currentShare != share {
		return ErrAssetChanged
	}
	return nil
}

// videoFingerprint hashes three bounded source ranges plus the version fields.
// It detects common in-place changes without reading/copying the full movie.
func videoFingerprint(source *os.File, info os.FileInfo) (string, error) {
	if info.Size() < 0 || !info.Mode().IsRegular() {
		return "", errors.New("invalid_video_source")
	}
	hasher := sha256.New()
	if _, err := fmt.Fprintf(hasher, "%d|%d|%s|", info.Size(), info.ModTime().UnixNano(), sourceFileGeneration(info)); err != nil {
		return "", err
	}
	length := min(videoFingerprintSampleBytes, info.Size())
	offsets := []int64{0, max(0, info.Size()/2-length/2), max(0, info.Size()-length)}
	var previous int64 = -1
	for _, offset := range offsets {
		if offset == previous || length == 0 {
			continue
		}
		previous = offset
		if _, err := fmt.Fprintf(hasher, "%d:", offset); err != nil {
			return "", err
		}
		if _, err := io.CopyN(hasher, io.NewSectionReader(source, offset, length), length); err != nil {
			return "", err
		}
	}
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func sourceFileGeneration(info os.FileInfo) string {
	value := reflect.ValueOf(info.Sys())
	if !value.IsValid() {
		return ""
	}
	if value.Kind() == reflect.Pointer {
		if value.IsNil() {
			return ""
		}
		value = value.Elem()
	}
	if value.Kind() != reflect.Struct {
		return ""
	}
	device := reflectedInteger(value.FieldByName("Dev"))
	inode := reflectedInteger(value.FieldByName("Ino"))
	change := value.FieldByName("Ctimespec")
	if !change.IsValid() {
		change = value.FieldByName("Ctim")
	}
	if change.IsValid() && change.Kind() == reflect.Struct {
		sec := reflectedInteger(change.FieldByName("Sec"))
		nsec := reflectedInteger(change.FieldByName("Nsec"))
		if nsec == "" {
			nsec = reflectedInteger(change.FieldByName("Nanosec"))
		}
		return device + ":" + inode + ":" + sec + ":" + nsec
	}
	return device + ":" + inode + ":" + strconv.FormatInt(info.ModTime().UnixNano(), 10)
}

func reflectedInteger(value reflect.Value) string {
	if !value.IsValid() {
		return ""
	}
	switch value.Kind() {
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return strconv.FormatInt(value.Int(), 10)
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		return strconv.FormatUint(value.Uint(), 10)
	default:
		return ""
	}
}
