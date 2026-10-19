package gallery

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// Thumbnail generates JPEG on first request, then serves it from a bounded
// cache. macOS sips supports HEIC and orientation through system codecs.
// Input is copied through os.Root-secured fd into a private temp file to
// prevent sips from following an untrusted symlink outside the share.
func (l *Library) Thumbnail(id int64) (*os.File, error) {
	a, err := l.Asset(id)
	if err != nil {
		return nil, err
	}
	if a.Type != "photo" {
		return nil, errors.New("not_a_photo")
	}
	if a.Size > 64<<20 {
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
	if !details.Mode().IsRegular() || details.Size() != a.Size {
		return nil, errors.New("asset_changed_rescan_required")
	}
	key := cacheID(share, a.Path, details.ModTime().UnixNano(), details.Size())
	if err := os.MkdirAll(l.cache, 0700); err != nil {
		return nil, err
	}
	destination := filepath.Join(l.cache, key+".jpg")
	if f, err := os.Open(destination); err == nil {
		return f, nil
	}

	l.thumbMu.Lock()
	defer l.thumbMu.Unlock()
	if f, err := os.Open(destination); err == nil {
		return f, nil
	}
	tmp, err := os.CreateTemp(l.cache, "input-")
	if err != nil {
		return nil, err
	}
	inputName := tmp.Name()
	defer os.Remove(inputName)
	// Copy at most 64MiB+1 into private worker input.
	_, err = io.Copy(tmp, io.LimitReader(source, (64<<20)+1))
	cerr := tmp.Close()
	if err != nil {
		return nil, err
	}
	if cerr != nil {
		return nil, cerr
	}
	output, err := os.CreateTemp(l.cache, "thumb-")
	if err != nil {
		return nil, err
	}
	outName := output.Name()
	output.Close()
	defer os.Remove(outName)
	ctx, cancel := context.WithTimeout(l.ctx, 20*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, "/usr/bin/sips", "-s", "format", "jpeg", "-Z", "512", inputName, "--out", outName)
	if result, err := command.CombinedOutput(); err != nil {
		_ = result
		return nil, errors.New("thumbnail_conversion_failed")
	}
	if stat, err := os.Stat(outName); err != nil || stat.Size() > 8<<20 {
		return nil, errors.New("thumbnail_invalid")
	}
	if err := os.Rename(outName, destination); err != nil {
		return nil, err
	}
	return os.Open(destination)
}
