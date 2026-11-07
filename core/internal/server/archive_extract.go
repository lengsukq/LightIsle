package server

import (
	"archive/zip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"sort"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/files"
)

const (
	extractMaxTotalBytes      = int64(4) << 30
	extractMaxSingleFileBytes = int64(1) << 30
)

var errZipSizeMismatch = errors.New("zip_entry_size_mismatch")

type zipExtractEntry struct {
	file    *zip.File
	relPath string
	size    int64
	isDir   bool
}

type exactZipEntryReader struct {
	r         io.Reader
	expected  int64
	readBytes int64
}

func (e *exactZipEntryReader) Read(p []byte) (int, error) {
	n, err := e.r.Read(p)
	e.readBytes += int64(n)
	if e.readBytes > e.expected {
		return n, errZipSizeMismatch
	}
	if errors.Is(err, io.EOF) && e.readBytes != e.expected {
		return n, errZipSizeMismatch
	}
	return n, err
}

func cleanZipEntryPath(raw string) (string, bool, error) {
	if raw == "" || strings.HasPrefix(raw, "/") || strings.ContainsAny(raw, "\\\x00") {
		return "", false, files.ErrPath
	}
	isDir := strings.HasSuffix(raw, "/")
	trimmed := strings.TrimSuffix(raw, "/")
	if trimmed == "" {
		return "", false, files.ErrPath
	}
	parts := strings.Split(trimmed, "/")
	if len(parts) > archiveMaxDepth {
		return "", false, errArchiveLimit
	}
	for _, part := range parts {
		if part == "" || part == "." || part == ".." || files.IsInternalName(part) {
			return "", false, files.ErrPath
		}
	}
	cleaned := path.Clean(trimmed)
	if cleaned == "." || cleaned != trimmed {
		return "", false, files.ErrPath
	}
	return cleaned, isDir, nil
}

func shouldSkipMacZipMetadata(relPath string) bool {
	if relPath == "__MACOSX" || strings.HasPrefix(relPath, "__MACOSX/") {
		return true
	}
	base := path.Base(relPath)
	return base == ".DS_Store" || strings.HasPrefix(base, "._")
}

func (a *API) extractZipArchive(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	if a.rootID != "" && (a.rootRuntime == nil || a.rootLease == nil || !a.rootLease.Valid(r.Context())) {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "root_unavailable"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	defer r.Body.Close()
	var body struct {
		Path string `json:"path"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if dec.Decode(&body) != nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	srcPath := path.Clean(strings.TrimSpace(body.Path))
	ext := path.Ext(srcPath)
	if srcPath == "" || srcPath == "." || !strings.EqualFold(ext, ".zip") {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_zip_archive"})
		return
	}
	stem := strings.TrimSuffix(path.Base(srcPath), ext)
	if stem == "" || stem == "." || stem == ".." || files.IsInternalName(stem) {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "path_not_allowed"})
		return
	}
	parentDir := path.Dir(srcPath)
	baseTarget := stem
	if parentDir != "." {
		baseTarget = path.Join(parentDir, stem)
	}
	if !a.allowFile(w, r, srcPath, false) || !a.allowFile(w, r, baseTarget, true) {
		return
	}
	if !acquireArchiveSlot(w, false) {
		return
	}
	defer func() { <-archiveSlots }()

	zipFile, zipInfo, err := a.files.Read(srcPath)
	if err != nil {
		fileError(w, err)
		return
	}
	defer zipFile.Close()
	if !zipInfo.Mode().IsRegular() || zipInfo.Size() <= 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_zip_archive"})
		return
	}
	if zipInfo.Size() > archiveMaxBytes {
		jsonReply(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "archive_limit_exceeded"})
		return
	}
	zr, err := zip.NewReader(zipFile, zipInfo.Size())
	if err != nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_zip_archive"})
		return
	}
	if len(zr.File) > archiveMaxEntries {
		jsonReply(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "archive_limit_exceeded"})
		return
	}

	plan, dirs, err := buildZipExtractPlan(zr.File)
	if err != nil {
		if errors.Is(err, errArchiveLimit) {
			jsonReply(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "archive_limit_exceeded"})
			return
		}
		if errors.Is(err, files.ErrType) {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "archive_unsafe_entry"})
			return
		}
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "path_not_allowed"})
		return
	}

	targetDir, err := createExtractTargetFolder(a.files, baseTarget)
	if err != nil {
		fileError(w, err)
		return
	}

	accounted := a.rootID != "" && managedStorageName(targetDir)
	reservations := make([]string, len(plan))
	if accounted {
		for idx, item := range plan {
			resID, tracked, resErr := a.reserveUploadQuota(r, path.Join(targetDir, item.relPath), item.size)
			if resErr != nil || !tracked || resID == "" {
				for prev := 0; prev < idx; prev++ {
					_ = a.auth.ReleaseStorageReservation(reservations[prev])
				}
				_ = a.files.MoveToTrash(targetDir)
				if resErr != nil {
					storageQuotaError(w, resErr)
					return
				}
				jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_destination_not_assigned"})
				return
			}
			reservations[idx] = resID
		}
	}

	releaseRemaining := func(fromIdx int) {
		if !accounted {
			return
		}
		for i := fromIdx; i < len(reservations); i++ {
			if reservations[i] != "" {
				_ = a.auth.ReleaseStorageReservation(reservations[i])
				reservations[i] = ""
			}
		}
	}

	for _, relDir := range dirs {
		if err := r.Context().Err(); err != nil {
			releaseRemaining(0)
			return
		}
		fullDir := path.Join(targetDir, relDir)
		if err := a.files.Mkdir(fullDir); err != nil && !errors.Is(err, files.ErrExists) && !errors.Is(err, fs.ErrExist) {
			releaseRemaining(0)
			fileError(w, err)
			return
		}
	}

	uploader, hasIdentityUploader := a.files.(interface {
		UploadWithIdentity(string, io.Reader) (int64, string, error)
	})

	extractedFiles := 0
	for idx, item := range plan {
		if err := r.Context().Err(); err != nil {
			releaseRemaining(idx)
			return
		}
		rc, openErr := item.file.Open()
		if openErr != nil {
			releaseRemaining(idx)
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_zip_archive"})
			return
		}
		reader := &exactZipEntryReader{r: rc, expected: item.size}
		destPath := path.Join(targetDir, item.relPath)
		var written int64
		var identity string
		var upErr error
		if accounted && hasIdentityUploader {
			written, identity, upErr = uploader.UploadWithIdentity(destPath, reader)
		} else {
			written, upErr = a.files.Upload(destPath, reader)
		}
		_ = rc.Close()
		if upErr != nil {
			if accounted && !errors.Is(upErr, files.ErrPublishedSync) {
				_ = a.auth.ReleaseStorageReservation(reservations[idx])
				reservations[idx] = ""
			}
			releaseRemaining(idx + 1)
			if errors.Is(upErr, errZipSizeMismatch) {
				jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_zip_archive"})
				return
			}
			uploadStreamError(w, upErr)
			return
		}
		if accounted {
			if written != item.size || a.rootLease == nil || !a.rootLease.Valid(r.Context()) {
				releaseRemaining(idx + 1)
				jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
				return
			}
			if err := a.auth.CommitStorageReservationWithIdentity(reservations[idx], identity); err != nil {
				releaseRemaining(idx + 1)
				jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
				return
			}
			reservations[idx] = ""
		}
		extractedFiles++
	}

	if a.rootID != "" && (a.rootLease == nil || !a.rootLease.Valid(r.Context())) {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "root_unavailable"})
		return
	}
	if a.rootServer != nil {
		a.rootServer.QueueMediaRefresh(a.rootID, targetDir)
	}
	jsonReply(w, http.StatusCreated, map[string]any{
		"extracted":  true,
		"targetPath": targetDir,
		"files":      extractedFiles,
	})
}

func buildZipExtractPlan(entries []*zip.File) ([]zipExtractEntry, []string, error) {
	filesPlan := make([]zipExtractEntry, 0, len(entries))
	dirSet := make(map[string]struct{})
	seenPaths := make(map[string]struct{}, len(entries))
	var totalBytes int64

	addAncestors := func(rel string) {
		for dir := path.Dir(rel); dir != "." && dir != ""; dir = path.Dir(dir) {
			dirSet[dir] = struct{}{}
		}
	}

	for _, item := range entries {
		rel, isDir, err := cleanZipEntryPath(item.Name)
		if err != nil {
			return nil, nil, err
		}
		if shouldSkipMacZipMetadata(rel) {
			continue
		}
		mode := item.Mode()
		if mode&os.ModeSymlink != 0 {
			return nil, nil, files.ErrType
		}
		if isDir || item.FileInfo().IsDir() {
			addAncestors(rel)
			dirSet[rel] = struct{}{}
			continue
		}
		if !mode.IsRegular() {
			return nil, nil, files.ErrType
		}
		if item.UncompressedSize64 > uint64(extractMaxSingleFileBytes) {
			return nil, nil, errArchiveLimit
		}
		size := int64(item.UncompressedSize64)
		if size > extractMaxTotalBytes-totalBytes {
			return nil, nil, errArchiveLimit
		}
		totalBytes += size
		lowerKey := strings.ToLower(rel)
		if _, dup := seenPaths[lowerKey]; dup {
			return nil, nil, files.ErrPath
		}
		seenPaths[lowerKey] = struct{}{}
		addAncestors(rel)
		filesPlan = append(filesPlan, zipExtractEntry{
			file:    item,
			relPath: rel,
			size:    size,
		})
	}

	dirs := make([]string, 0, len(dirSet))
	for d := range dirSet {
		dirs = append(dirs, d)
	}
	sort.Slice(dirs, func(i, j int) bool {
		di, dj := strings.Count(dirs[i], "/"), strings.Count(dirs[j], "/")
		if di != dj {
			return di < dj
		}
		return dirs[i] < dirs[j]
	})
	return filesPlan, dirs, nil
}

func createExtractTargetFolder(access files.Access, baseTarget string) (string, error) {
	for attempt := 1; attempt <= 100; attempt++ {
		candidate := baseTarget
		if attempt > 1 {
			candidate = fmt.Sprintf("%s (%d)", baseTarget, attempt)
		}
		err := access.Mkdir(candidate)
		if err == nil {
			return candidate, nil
		}
		if errors.Is(err, files.ErrExists) || errors.Is(err, fs.ErrExist) {
			continue
		}
		return "", err
	}
	return "", files.ErrExists
}
