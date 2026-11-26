package server

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path"
	"sort"
	"strconv"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

const (
	readerArchiveMaxBytes        = int64(512) << 20 // 512 MiB container file cap
	readerArchiveMaxEntries      = 2000
	readerArchiveMaxSingleBytes  = int64(32) << 20 // 32 MiB single entry cap
	readerArchiveMaxTotalBytes   = int64(2) << 30  // 2 GiB cumulative uncompressed cap
	readerArchiveMaxBombRatio    = 100
	readerArchiveBombRatioCutoff = int64(1) << 20 // inspect ratio when uncompressed > 1 MiB
)

type archiveEntryDescriptor struct {
	Index int    `json:"index"`
	Name  string `json:"name"`
	Size  int64  `json:"size"`
	MIME  string `json:"mime"`
	Kind  string `json:"kind"`
}

func cleanReadableZipEntryPath(raw string) (string, bool, error) {
	normalized := strings.ReplaceAll(raw, "\\", "/")
	return cleanZipEntryPath(normalized)
}

func readableArchiveFormat(relPath string) (string, bool) {
	switch strings.ToLower(path.Ext(relPath)) {
	case ".cbz":
		return "cbz", true
	case ".zip":
		return "zip", true
	case ".epub":
		return "epub", true
	default:
		return "", false
	}
}

// classifyArchiveEntryMIME enforces a strict whitelist of safe comic/EPUB
// resource types. Executable scripts (.js/.mjs), binaries, and unknown types
// are explicitly refused.
func classifyArchiveEntryMIME(entryName string) (mimeType, kind string, ok bool) {
	base := strings.ToLower(path.Base(entryName))
	if base == "mimetype" {
		return "text/plain; charset=utf-8", "metadata", true
	}
	switch strings.ToLower(path.Ext(base)) {
	case ".jpg", ".jpeg":
		return "image/jpeg", "image", true
	case ".png":
		return "image/png", "image", true
	case ".gif":
		return "image/gif", "image", true
	case ".webp":
		return "image/webp", "image", true
	case ".avif":
		return "image/avif", "image", true
	case ".bmp":
		return "image/bmp", "image", true
	case ".svg":
		return "image/svg+xml", "image", true
	case ".xhtml":
		return "application/xhtml+xml; charset=utf-8", "document", true
	case ".html", ".htm":
		return "text/html; charset=utf-8", "document", true
	case ".xml", ".opf", ".ncx", ".smil":
		return "application/xml; charset=utf-8", "metadata", true
	case ".css":
		return "text/css; charset=utf-8", "style", true
	case ".txt", ".md":
		return "text/plain; charset=utf-8", "document", true
	case ".json":
		return "application/json; charset=utf-8", "metadata", true
	case ".woff":
		return "font/woff", "font", true
	case ".woff2":
		return "font/woff2", "font", true
	case ".ttf":
		return "font/ttf", "font", true
	case ".otf":
		return "font/otf", "font", true
	default:
		return "", "", false
	}
}

func checkZipBombEntry(item *zip.File) error {
	if item.UncompressedSize64 > uint64(readerArchiveMaxSingleBytes) {
		return errArchiveLimit
	}
	uncomp := int64(item.UncompressedSize64)
	comp := int64(item.CompressedSize64)
	if uncomp > readerArchiveBombRatioCutoff && comp > 0 && uncomp/comp > readerArchiveMaxBombRatio {
		return errArchiveLimit
	}
	return nil
}

func (a *API) openReadableArchive(w http.ResponseWriter, r *http.Request) (*os.File, os.FileInfo, *zip.Reader, string, string, bool) {
	if a.files == nil {
		a.fileUnavailable(w)
		return nil, nil, nil, "", "", false
	}
	cleanPath := cleanClientRelativePath(r.URL.Query().Get("path"))
	if cleanPath == "" {
		writeAPIErrorCode(w, http.StatusBadRequest, "path_not_allowed")
		return nil, nil, nil, "", "", false
	}
	format, ok := readableArchiveFormat(cleanPath)
	if !ok {
		writeAPIErrorCode(w, http.StatusUnsupportedMediaType, "archive_reader_unsupported")
		return nil, nil, nil, "", "", false
	}
	if !a.allowFile(w, r, cleanPath, false) {
		return nil, nil, nil, "", "", false
	}
	f, info, err := a.files.Read(cleanPath)
	if err != nil {
		fileError(w, err)
		return nil, nil, nil, "", "", false
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 {
		_ = f.Close()
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_zip_archive")
		return nil, nil, nil, "", "", false
	}
	if info.Size() > readerArchiveMaxBytes {
		_ = f.Close()
		writeAPIErrorCode(w, http.StatusRequestEntityTooLarge, "archive_limit_exceeded")
		return nil, nil, nil, "", "", false
	}
	zr, err := zip.NewReader(f, info.Size())
	if err != nil {
		_ = f.Close()
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_zip_archive")
		return nil, nil, nil, "", "", false
	}
	if len(zr.File) > readerArchiveMaxEntries {
		_ = f.Close()
		writeAPIErrorCode(w, http.StatusRequestEntityTooLarge, "archive_limit_exceeded")
		return nil, nil, nil, "", "", false
	}
	return f, info, zr, cleanPath, format, true
}

func (a *API) fileArchiveEntries(w http.ResponseWriter, r *http.Request) {
	f, info, zr, cleanPath, format, ok := a.openReadableArchive(w, r)
	if !ok {
		return
	}
	defer f.Close()

	entries := make([]archiveEntryDescriptor, 0, len(zr.File))
	var cumulative int64
	for idx, item := range zr.File {
		rel, isDir, err := cleanReadableZipEntryPath(item.Name)
		if err != nil || isDir || item.FileInfo().IsDir() {
			continue
		}
		if shouldSkipMacZipMetadata(rel) {
			continue
		}
		if item.Mode()&os.ModeSymlink != 0 || !item.Mode().IsRegular() {
			continue
		}
		if err := checkZipBombEntry(item); err != nil {
			writeAPIErrorCode(w, http.StatusRequestEntityTooLarge, "archive_limit_exceeded")
			return
		}
		size := int64(item.UncompressedSize64)
		if size > readerArchiveMaxTotalBytes-cumulative {
			writeAPIErrorCode(w, http.StatusRequestEntityTooLarge, "archive_limit_exceeded")
			return
		}
		cumulative += size
		mimeType, kind, allowed := classifyArchiveEntryMIME(rel)
		if !allowed {
			continue
		}
		entries = append(entries, archiveEntryDescriptor{
			Index: idx,
			Name:  strings.ToValidUTF8(rel, "\uFFFD"),
			Size:  size,
			MIME:  mimeType,
			Kind:  kind,
		})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Name != entries[j].Name {
			return naturalPathLess(entries[i].Name, entries[j].Name)
		}
		return entries[i].Index < entries[j].Index
	})
	jsonReply(w, http.StatusOK, map[string]any{
		"path":          cleanPath,
		"format":        format,
		"size":          info.Size(),
		"mtimeUnixNano": info.ModTime().UnixNano(),
		"entryCount":    len(entries),
		"entries":       entries,
	})
}

func (a *API) fileArchiveEntry(w http.ResponseWriter, r *http.Request) {
	rawIndex := strings.TrimSpace(r.URL.Query().Get("index"))
	rawEntry := r.URL.Query().Get("entry")

	var requestedIdx int
	useIndex := rawIndex != ""
	var cleanEntry string
	var mimeType string
	if useIndex {
		parsedIdx, parseErr := strconv.Atoi(rawIndex)
		if parseErr != nil || parsedIdx < 0 {
			writeAPIErrorCode(w, http.StatusBadRequest, "path_not_allowed")
			return
		}
		requestedIdx = parsedIdx
	} else {
		var isDir bool
		var err error
		cleanEntry, isDir, err = cleanReadableZipEntryPath(rawEntry)
		if err != nil || isDir || shouldSkipMacZipMetadata(cleanEntry) {
			writeAPIErrorCode(w, http.StatusBadRequest, "path_not_allowed")
			return
		}
		var allowed bool
		mimeType, _, allowed = classifyArchiveEntryMIME(cleanEntry)
		if !allowed {
			writeAPIErrorCode(w, http.StatusUnsupportedMediaType, "archive_entry_type_forbidden")
			return
		}
	}

	f, info, zr, cleanPath, _, ok := a.openReadableArchive(w, r)
	if !ok {
		return
	}
	defer f.Close()

	var target *zip.File
	var targetIdx int
	var targetRel string
	if useIndex {
		if requestedIdx >= len(zr.File) {
			writeAPIErrorCode(w, http.StatusNotFound, "not_found")
			return
		}
		item := zr.File[requestedIdx]
		rel, dirFlag, cleanErr := cleanReadableZipEntryPath(item.Name)
		if cleanErr != nil || dirFlag || item.FileInfo().IsDir() || shouldSkipMacZipMetadata(rel) {
			writeAPIErrorCode(w, http.StatusBadRequest, "archive_unsafe_entry")
			return
		}
		var allowed bool
		mimeType, _, allowed = classifyArchiveEntryMIME(rel)
		if !allowed {
			writeAPIErrorCode(w, http.StatusUnsupportedMediaType, "archive_entry_type_forbidden")
			return
		}
		target = item
		targetIdx = requestedIdx
		targetRel = rel
	} else {
		for idx, item := range zr.File {
			rel, dirFlag, cleanErr := cleanReadableZipEntryPath(item.Name)
			if cleanErr != nil || dirFlag || item.FileInfo().IsDir() {
				continue
			}
			if rel == cleanEntry {
				target = item
				targetIdx = idx
				targetRel = rel
				break
			}
		}
	}
	if target == nil {
		writeAPIErrorCode(w, http.StatusNotFound, "not_found")
		return
	}
	if target.Mode()&os.ModeSymlink != 0 || !target.Mode().IsRegular() {
		writeAPIErrorCode(w, http.StatusBadRequest, "archive_unsafe_entry")
		return
	}
	if err := checkZipBombEntry(target); err != nil {
		writeAPIErrorCode(w, http.StatusRequestEntityTooLarge, "archive_limit_exceeded")
		return
	}

	etagSum := sha256.Sum256([]byte(cleanPath + "|" + strconv.Itoa(targetIdx) + "|" + targetRel + "|" + strconv.FormatInt(info.Size(), 16) + "|" + strconv.FormatInt(info.ModTime().UnixNano(), 16)))
	etag := `"` + hex.EncodeToString(etagSum[:16]) + `"`
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "private, max-age=300")
	if ifNoneMatchContains(r.Header.Get("If-None-Match"), etag) {
		w.WriteHeader(http.StatusNotModified)
		return
	}

	rc, err := target.Open()
	if err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_zip_archive")
		return
	}
	defer rc.Close()

	expected := int64(target.UncompressedSize64)
	w.Header().Set("Content-Type", mimeType)
	w.Header().Set("Content-Length", strconv.FormatInt(expected, 10))
	w.Header().Set("Content-Disposition", "inline")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; sandbox")
	w.WriteHeader(http.StatusOK)

	bounded := &exactZipEntryReader{r: io.LimitReader(rc, expected+1), expected: expected}
	if _, copyErr := io.Copy(w, bounded); copyErr != nil {
		// Response headers already committed; abort stream on zip-bomb / size mismatch.
		panic(http.ErrAbortHandler)
	}
}

func (a *API) fileReadingProgressGet(w http.ResponseWriter, r *http.Request) {
	tok := token(r)
	rootID, gen := a.effectiveRootScope()
	rawPath := strings.TrimSpace(r.URL.Query().Get("path"))
	if rawPath != "" {
		cleanPath := cleanClientRelativePath(rawPath)
		if cleanPath == "" {
			writeAPIErrorCode(w, http.StatusBadRequest, "path_not_allowed")
			return
		}
		if !a.allowFile(w, r, cleanPath, false) {
			return
		}
		progress, found, err := a.auth.GetReadingProgress(tok, rootID, gen, cleanPath)
		if err != nil {
			writeReadingProgressError(w, err)
			return
		}
		resp := map[string]any{"found": found}
		if found {
			resp["progress"] = progress
		}
		jsonReply(w, http.StatusOK, resp)
		return
	}
	limit := 50
	if rawLimit := strings.TrimSpace(r.URL.Query().Get("limit")); rawLimit != "" {
		parsed, err := strconv.Atoi(rawLimit)
		if err != nil || parsed < 1 || parsed > 100 {
			writeAPIErrorCode(w, http.StatusBadRequest, "invalid_limit")
			return
		}
		limit = parsed
	}
	items, err := a.auth.ListReadingProgress(tok, rootID, gen, limit)
	if err != nil {
		writeReadingProgressError(w, err)
		return
	}
	visible := make([]auth.ReadingProgress, 0, len(items))
	for _, it := range items {
		if a.canAccess(tok, it.Path, false, false) {
			visible = append(visible, it)
		}
	}
	jsonReply(w, http.StatusOK, map[string]any{"items": visible})
}

func (a *API) fileReadingProgressPut(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	defer r.Body.Close()
	var body struct {
		Path    string  `json:"path"`
		Locator string  `json:"locator"`
		Percent float64 `json:"percent"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
		return
	}
	cleanPath := cleanClientRelativePath(body.Path)
	if cleanPath == "" {
		writeAPIErrorCode(w, http.StatusBadRequest, "path_not_allowed")
		return
	}
	if !a.allowFile(w, r, cleanPath, false) {
		return
	}
	rootID, gen := a.effectiveRootScope()
	progress, err := a.auth.UpsertReadingProgress(token(r), rootID, gen, cleanPath, body.Locator, body.Percent)
	if err != nil {
		writeReadingProgressError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"progress": progress})
}

func writeReadingProgressError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, auth.ErrInput):
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_reading_progress")
	case errors.Is(err, auth.ErrForbidden):
		writeAPIErrorCode(w, http.StatusForbidden, "file_permission_denied")
	default:
		writeAPIErrorCode(w, http.StatusInternalServerError, "reading_progress_error")
	}
}

// naturalPathLess compares paths with numeric runs sorted numerically so comic
// pages like page2.jpg sort before page10.jpg.
func naturalPathLess(a, b string) bool {
	la, lb := strings.ToLower(a), strings.ToLower(b)
	ia, ib := 0, 0
	for ia < len(la) && ib < len(lb) {
		ca, cb := la[ia], lb[ib]
		if ca >= '0' && ca <= '9' && cb >= '0' && cb <= '9' {
			ea, eb := ia, ib
			for ea < len(la) && la[ea] >= '0' && la[ea] <= '9' {
				ea++
			}
			for eb < len(lb) && lb[eb] >= '0' && lb[eb] <= '9' {
				eb++
			}
			na := strings.TrimLeft(la[ia:ea], "0")
			nb := strings.TrimLeft(lb[ib:eb], "0")
			if len(na) != len(nb) {
				return len(na) < len(nb)
			}
			if na != nb {
				return na < nb
			}
			if ea-ia != eb-ib {
				return (ea - ia) < (eb - ib)
			}
			ia, ib = ea, eb
			continue
		}
		if ca != cb {
			return ca < cb
		}
		ia++
		ib++
	}
	if len(la) != len(lb) {
		return len(la) < len(lb)
	}
	return a < b
}
