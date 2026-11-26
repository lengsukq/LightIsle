//go:build darwin && arm64

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/diskmgmt"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

const (
	maxMediaImportWalkDepth   = 16
	maxMediaImportScanFiles   = 50_000
	maxMediaImportSampleFiles = 8
)

type mediaKind string

const (
	mediaKindPhoto     mediaKind = "photo"
	mediaKindRaw       mediaKind = "raw"
	mediaKindVideo     mediaKind = "video"
	mediaKindLivePhoto mediaKind = "live_photo"
)

type scannedMediaItem struct {
	FullPath string
	RelPath  string
	FileName string
	Size     int64
	ModTime  time.Time
	Kind     mediaKind
}

var (
	mediaPhotoExts = map[string]bool{
		".jpg": true, ".jpeg": true, ".png": true, ".heic": true, ".heif": true,
		".webp": true, ".tif": true, ".tiff": true, ".gif": true, ".bmp": true,
		".avif": true, ".jxl": true,
	}
	mediaRawExts = map[string]bool{
		".dng": true, ".cr2": true, ".cr3": true, ".nef": true, ".nrw": true,
		".arw": true, ".srf": true, ".sr2": true, ".raf": true, ".orf": true,
		".rw2": true, ".pef": true, ".srw": true, ".3fr": true, ".iiq": true,
		".rwl": true, ".x3f": true,
	}
	mediaVideoExts = map[string]bool{
		".mp4": true, ".mov": true, ".m4v": true, ".avi": true, ".mkv": true,
		".mts": true, ".m2ts": true, ".mpg": true, ".mpeg": true, ".3gp": true,
		".insv": true, ".braw": true, ".r3d": true, ".mxf": true,
	}
	mediaHintDirs = map[string]string{
		"dcim":    "DCIM",
		"private": "PRIVATE",
		"dji":     "DJI",
		"avchd":   "AVCHD",
		"mp_root": "MP_ROOT",
		"cardv":   "CardV",
		"movie":   "Movie",
	}
	mediaIgnoredDirs = map[string]bool{
		"system volume information": true,
		"$recycle.bin":              true,
	}
)

func (c *mediaImportControl) validateSourcePath(raw string) (string, string) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || !filepath.IsAbs(trimmed) {
		return "", "source_path_outside_volumes"
	}
	prefix := c.allowedSourcePrefix
	if prefix == "" {
		prefix = "/Volumes"
	}
	if canonicalPrefix, err := filepath.EvalSymlinks(prefix); err == nil {
		prefix = filepath.Clean(canonicalPrefix)
	} else {
		prefix = filepath.Clean(prefix)
	}
	resolved, err := filepath.EvalSymlinks(trimmed)
	if err != nil {
		return "", classifySourceStatError(err)
	}
	resolved = filepath.Clean(resolved)
	if resolved == "/" || resolved == prefix || !strings.HasPrefix(resolved, prefix+string(filepath.Separator)) {
		return "", "source_path_outside_volumes"
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", classifySourceStatError(err)
	}
	if !info.IsDir() {
		return "", "source_not_directory"
	}
	if c.registry != nil {
		for _, r := range c.registry.List() {
			if r.Path != "" && rootPathsOverlap(resolved, r.Path) {
				return "", "source_overlaps_nas_root"
			}
		}
	}
	return resolved, ""
}

func classifySourceStatError(err error) string {
	if errors.Is(err, os.ErrNotExist) {
		return "source_not_found"
	}
	if errors.Is(err, os.ErrPermission) || errors.Is(err, syscall.EACCES) || errors.Is(err, syscall.EPERM) {
		return "source_permission_denied"
	}
	return "source_not_found"
}

func scanRemovableMediaSource(ctx context.Context, sourcePath string) (mediaImportScanResult, []scannedMediaItem, error) {
	result := mediaImportScanResult{
		SourcePath: sourcePath,
		VolumeName: filepath.Base(sourcePath),
	}
	hintsSeen := map[string]bool{}
	items := make([]scannedMediaItem, 0, 128)
	photoStemsByDir := map[string]map[string]bool{}

	var walk func(absDir, relDir string, depth int) error
	walk = func(absDir, relDir string, depth int) error {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if depth > maxMediaImportWalkDepth {
			return nil
		}
		entries, err := os.ReadDir(absDir)
		if err != nil {
			if depth == 0 {
				return err
			}
			return nil
		}
		for _, entry := range entries {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			name := entry.Name()
			if shouldSkipMediaEntryName(name) || entry.Type()&os.ModeSymlink != 0 {
				continue
			}
			childAbs := filepath.Join(absDir, name)
			childRel := name
			if relDir != "" {
				childRel = relDir + "/" + name
			}
			if entry.IsDir() {
				if depth <= 1 {
					if label, ok := mediaHintDirs[strings.ToLower(name)]; ok && !hintsSeen[label] {
						hintsSeen[label] = true
						result.DetectedHints = append(result.DetectedHints, label)
					}
				}
				if err := walk(childAbs, childRel, depth+1); err != nil {
					return err
				}
				if result.Truncated {
					return nil
				}
				continue
			}
			kind, ok := classifyMediaExtension(name)
			if !ok {
				continue
			}
			info, statErr := entry.Info()
			if statErr != nil || !info.Mode().IsRegular() {
				continue
			}
			if len(items) >= maxMediaImportScanFiles {
				result.Truncated = true
				return nil
			}
			if kind == mediaKindPhoto || kind == mediaKindRaw {
				stems := photoStemsByDir[relDir]
				if stems == nil {
					stems = make(map[string]bool)
					photoStemsByDir[relDir] = stems
				}
				stems[strings.ToLower(strings.TrimSuffix(name, filepath.Ext(name)))] = true
			}
			items = append(items, scannedMediaItem{
				FullPath: childAbs,
				RelPath:  childRel,
				FileName: name,
				Size:     info.Size(),
				ModTime:  info.ModTime(),
				Kind:     kind,
			})
		}
		return nil
	}

	if err := walk(sourcePath, "", 0); err != nil {
		return mediaImportScanResult{}, nil, err
	}

	sort.Slice(items, func(i, j int) bool { return items[i].RelPath < items[j].RelPath })
	sort.Strings(result.DetectedHints)

	for i := range items {
		if items[i].Kind == mediaKindVideo && strings.EqualFold(filepath.Ext(items[i].FileName), ".mov") {
			parentRel := path.Dir(items[i].RelPath)
			if parentRel == "." {
				parentRel = ""
			}
			stem := strings.ToLower(strings.TrimSuffix(items[i].FileName, filepath.Ext(items[i].FileName)))
			if photoStemsByDir[parentRel][stem] {
				items[i].Kind = mediaKindLivePhoto
			}
		}
		result.TotalFiles++
		result.TotalBytes += items[i].Size
		switch items[i].Kind {
		case mediaKindPhoto:
			result.PhotoCount++
		case mediaKindRaw:
			result.RawCount++
		case mediaKindVideo:
			result.VideoCount++
		case mediaKindLivePhoto:
			result.LivePhotoCount++
		}
		if len(result.SampleFiles) < maxMediaImportSampleFiles {
			result.SampleFiles = append(result.SampleFiles, items[i].RelPath)
		}
	}
	return result, items, nil
}

func shouldSkipMediaEntryName(name string) bool {
	if name == "" || strings.HasPrefix(name, ".") {
		return true
	}
	if files.IsInternalName(name) || files.IsSystemMetadataName(name) {
		return true
	}
	return mediaIgnoredDirs[strings.ToLower(name)]
}

func classifyMediaExtension(fileName string) (mediaKind, bool) {
	ext := strings.ToLower(filepath.Ext(fileName))
	if mediaPhotoExts[ext] {
		return mediaKindPhoto, true
	}
	if mediaRawExts[ext] {
		return mediaKindRaw, true
	}
	if mediaVideoExts[ext] {
		return mediaKindVideo, true
	}
	return "", false
}

func resolveDeduplicatedTarget(
	ctx context.Context,
	manager *files.Manager,
	binding storageidentity.Binding,
	desiredRel string,
	sourceSize int64,
	getSourceHash func() (string, error),
) (string, bool, error) {
	dir := path.Dir(desiredRel)
	base := path.Base(desiredRel)
	ext := path.Ext(base)
	stem := strings.TrimSuffix(base, ext)

	for attempt := 0; attempt < 1000; attempt++ {
		if ctx.Err() != nil {
			return "", false, ctx.Err()
		}
		candidate := desiredRel
		if attempt > 0 {
			name := fmt.Sprintf("%s_%d%s", stem, attempt, ext)
			if dir == "." {
				candidate = name
			} else {
				candidate = dir + "/" + name
			}
		}
		matchedDuplicate := false
		inspectErr := manager.InspectDownload(binding, candidate, func(r io.Reader, existingSize int64) error {
			if existingSize != sourceSize {
				return nil
			}
			srcHash, hashErr := getSourceHash()
			if hashErr != nil {
				return hashErr
			}
			dstHash, dstErr := hashReaderSHA256(ctx, r)
			if dstErr != nil {
				return dstErr
			}
			if dstHash == srcHash {
				matchedDuplicate = true
			}
			return nil
		})
		if errors.Is(inspectErr, os.ErrNotExist) {
			return candidate, false, nil
		}
		if inspectErr != nil {
			return "", false, inspectErr
		}
		if matchedDuplicate {
			return candidate, true, nil
		}
	}
	return "", false, errors.New("media_import_too_many_conflicts")
}

func buildArchiveRelativePath(baseRel, subfolder, archiveMode string, item scannedMediaItem) (string, error) {
	fileName := sanitizePathSegment(item.FileName)
	if fileName == "" {
		return "", errors.New("invalid_filename")
	}
	parts := make([]string, 0, 8)
	if base := strings.Trim(baseRel, "/"); base != "" {
		parts = append(parts, base)
	}
	if sub := strings.Trim(subfolder, "/"); sub != "" {
		parts = append(parts, sub)
	}
	switch archiveMode {
	case "ym":
		t := item.ModTime
		parts = append(parts, fmt.Sprintf("%04d", t.Year()), fmt.Sprintf("%02d", int(t.Month())))
	case "preserve":
		relDir := path.Dir(item.RelPath)
		if relDir != "." && relDir != "" {
			for _, seg := range strings.Split(relDir, "/") {
				if clean := sanitizePathSegment(seg); clean != "" {
					parts = append(parts, clean)
				}
			}
		}
	default:
		t := item.ModTime
		parts = append(parts, fmt.Sprintf("%04d", t.Year()), fmt.Sprintf("%02d", int(t.Month())), fmt.Sprintf("%02d", t.Day()))
	}
	parts = append(parts, fileName)
	return strings.Join(parts, "/"), nil
}

func normalizeMediaArchiveMode(raw string) (string, bool) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "", "ymd", "yyyy/mm/dd":
		return "ymd", true
	case "ym", "yyyy/mm":
		return "ym", true
	case "preserve", "card":
		return "preserve", true
	default:
		return "", false
	}
}

func sanitizeMediaImportSubfolder(raw string) (string, bool) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", true
	}
	if strings.ContainsRune(trimmed, '\\') || strings.HasPrefix(trimmed, "/") || strings.ContainsRune(trimmed, 0) {
		return "", false
	}
	rawParts := strings.Split(trimmed, "/")
	if len(rawParts) > 4 {
		return "", false
	}
	cleanParts := make([]string, 0, len(rawParts))
	for _, seg := range rawParts {
		seg = strings.TrimSpace(seg)
		if seg == "" || seg == "." || seg == ".." || len(seg) > 64 ||
			files.IsInternalName(seg) || files.IsSystemMetadataName(seg) || strings.ContainsAny(seg, "\r\n\t") {
			return "", false
		}
		cleanParts = append(cleanParts, seg)
	}
	return strings.Join(cleanParts, "/"), true
}

func sanitizePathSegment(seg string) string {
	seg = strings.TrimSpace(seg)
	if seg == "" || seg == "." || seg == ".." || strings.ContainsAny(seg, "/\\\x00\r\n") {
		return ""
	}
	if files.IsInternalName(seg) || files.IsSystemMetadataName(seg) {
		return ""
	}
	return seg
}

func joinRelativePrefix(base, sub string) string {
	b, s := strings.Trim(base, "/"), strings.Trim(sub, "/")
	if b == "" {
		return s
	}
	if s == "" {
		return b
	}
	return b + "/" + s
}

func hashLocalFileSHA256(ctx context.Context, fullPath string) (string, error) {
	f, err := os.Open(fullPath)
	if err != nil {
		return "", err
	}
	defer func() { _ = f.Close() }()
	return hashReaderSHA256(ctx, f)
}

func hashReaderSHA256(ctx context.Context, r io.Reader) (string, error) {
	h := sha256.New()
	buf := make([]byte, 128*1024)
	for {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		n, err := r.Read(buf)
		if n > 0 {
			_, _ = h.Write(buf[:n])
		}
		if errors.Is(err, io.EOF) {
			return hex.EncodeToString(h.Sum(nil)), nil
		}
		if err != nil {
			return "", err
		}
	}
}

type ctxReader struct {
	ctx context.Context
	r   io.Reader
}

func (c *ctxReader) Read(p []byte) (int, error) {
	if c.ctx.Err() != nil {
		return 0, c.ctx.Err()
	}
	return c.r.Read(p)
}

func terminalPhaseForError(ctx context.Context, err error) string {
	if ctx.Err() != nil || errors.Is(err, context.Canceled) {
		return "cancelled"
	}
	return "failed"
}

func isFatalMediaImportError(err error, errCode string) bool {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	switch errCode {
	case "root_unavailable", "storage_quota_exceeded", "storage_disk_full",
		"storage_permission_os_denied", "media_import_cancelled", "storage_accounting_uncertain":
		return true
	default:
		return false
	}
}

func classifyMediaImportError(err error) string {
	if err == nil {
		return ""
	}
	switch {
	case errors.Is(err, context.Canceled):
		return "media_import_cancelled"
	case errors.Is(err, context.DeadlineExceeded):
		return "media_import_timed_out"
	case errors.Is(err, errMediaImportAccountingUncertain):
		return "storage_accounting_uncertain"
	case errors.Is(err, errMediaImportSizeMismatch):
		return "media_import_size_mismatch"
	case errors.Is(err, auth.ErrStorageQuotaExceeded):
		return "storage_quota_exceeded"
	case errors.Is(err, auth.ErrForbidden):
		return "storage_permission_denied"
	case errors.Is(err, auth.ErrNotFound):
		return "user_not_found"
	case errors.Is(err, roots.ErrOffline), errors.Is(err, roots.ErrStale),
		errors.Is(err, files.ErrDownloadRootChanged), errors.Is(err, files.ErrDownloadRootUnavailable):
		return "root_unavailable"
	case errors.Is(err, roots.ErrMissing):
		return "root_not_found"
	case errors.Is(err, diskmgmt.ErrBusy):
		return "disk_busy"
	case errors.Is(err, syscall.ENOSPC), errors.Is(err, files.ErrInsufficientSpace):
		return "storage_disk_full"
	case errors.Is(err, os.ErrPermission), errors.Is(err, syscall.EROFS),
		errors.Is(err, syscall.EACCES), errors.Is(err, syscall.EPERM):
		return "storage_permission_os_denied"
	default:
		return "media_import_failed"
	}
}
