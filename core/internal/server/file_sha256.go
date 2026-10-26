package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"reflect"
	"strconv"
	"strings"
)

// Hash only a bounded ordinary file already exposed through the authenticated
// file-read capability. This never follows or resolves client filesystem paths.
const maxVerifiedFileBytes int64 = 2 << 30

// Large originals are verified as bounded, independently authorized ranges.
// Keep both limits below the resumable upload cap and never hash a 32 GiB file
// in one synchronous request.
const (
	maxRangeVerifiedFileBytes int64 = 32 << 30
	maxFileHashRangeBytes     int64 = 4 << 20
)

var processFileHashSlots = make(chan struct{}, 2)

var rangeFileSystemAPFSProbe = fileSystemIsAPFS

type contextHashReader struct {
	ctx context.Context
	r   io.Reader
}

func (c contextHashReader) Read(buf []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.r.Read(buf)
}

func (a *API) fileSHA256(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("path")
	if !a.allowFile(w, r, name, false) {
		return
	}
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	if r.Context().Err() != nil {
		return
	}
	mode := r.URL.Query().Get("mode")
	if mode == "range" {
		a.fileSHA256Range(w, r, name)
		return
	}
	if mode != "" || r.URL.Query().Has("offset") || r.URL.Query().Has("length") || r.URL.Query().Has("version") {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_verification_mode"})
		return
	}
	slots := a.fileHashSlots
	if slots == nil {
		slots = processFileHashSlots
	}
	select {
	case slots <- struct{}{}:
		defer func() { <-slots }()
	default:
		w.Header().Set("Retry-After", "1")
		jsonReply(w, http.StatusTooManyRequests, map[string]string{"error": "file_hash_busy"})
		return
	}
	first, before, err := a.files.Read(name)
	if err != nil {
		fileError(w, err)
		return
	}
	defer first.Close()
	if !before.Mode().IsRegular() {
		jsonReply(w, 400, map[string]string{"error": "not_a_regular_file"})
		return
	}
	if before.Size() < 0 || before.Size() > maxVerifiedFileBytes {
		jsonReply(w, 413, map[string]string{"error": "verification_size_limit"})
		return
	}
	hasher := sha256.New()
	// A file may grow after the initial stat. Stop after the expected size
	// plus one byte rather than reading an actively growing file forever.
	copied, err := io.CopyBuffer(hasher, io.LimitReader(contextHashReader{ctx: r.Context(), r: first}, before.Size()+1), make([]byte, 128*1024))
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return
		}
		jsonReply(w, 503, map[string]string{"error": "verification_read_failed"})
		return
	}
	changed, statErr := first.Stat()
	if statErr != nil || copied != before.Size() || !os.SameFile(before, changed) ||
		!changed.ModTime().Equal(before.ModTime()) || changed.Size() != before.Size() {
		jsonReply(w, 409, map[string]string{"error": "file_changed_during_verification"})
		return
	}
	// Confirm this is still the object at the caller's authorized path and
	// that the underlying root is still online, not a replaced same-name disk.
	latest, latestInfo, err := a.files.Read(name)
	if err != nil {
		fileError(w, err)
		return
	}
	latest.Close()
	if !os.SameFile(before, latestInfo) || latestInfo.Size() != before.Size() ||
		!latestInfo.ModTime().Equal(before.ModTime()) {
		jsonReply(w, 409, map[string]string{"error": "file_changed_during_verification"})
		return
	}
	jsonReply(w, 200, map[string]any{
		"algorithm": "sha256",
		"sha256":    hex.EncodeToString(hasher.Sum(nil)),
		"size":      copied,
	})
}

func (a *API) fileSHA256Range(w http.ResponseWriter, r *http.Request, name string) {
	offset, offsetOK := parseNonNegativeInt64(r.URL.Query().Get("offset"))
	length, lengthOK := parseNonNegativeInt64(r.URL.Query().Get("length"))
	if !offsetOK || !lengthOK || length == 0 || length > maxFileHashRangeBytes {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_verification_range"})
		return
	}
	expectedVersion := r.URL.Query().Get("version")
	if offset != 0 && expectedVersion == "" {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "verification_version_required"})
		return
	}

	slots := a.fileHashSlots
	if slots == nil {
		slots = processFileHashSlots
	}
	select {
	case slots <- struct{}{}:
		defer func() { <-slots }()
	default:
		w.Header().Set("Retry-After", "1")
		jsonReply(w, http.StatusTooManyRequests, map[string]string{"error": "file_hash_busy"})
		return
	}
	if r.Context().Err() != nil {
		return
	}

	first, before, err := a.files.Read(name)
	if err != nil {
		fileError(w, err)
		return
	}
	defer first.Close()
	supportedFilesystem, fsErr := rangeFileSystemAPFSProbe(first)
	if fsErr != nil {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "verification_filesystem_unavailable"})
		return
	}
	if !supportedFilesystem {
		jsonReply(w, http.StatusNotImplemented, map[string]string{"error": "verification_filesystem_unsupported"})
		return
	}
	if !before.Mode().IsRegular() {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "not_a_regular_file"})
		return
	}
	if before.Size() < 0 || before.Size() > maxRangeVerifiedFileBytes {
		jsonReply(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "verification_size_limit"})
		return
	}
	// Subtraction avoids overflow in offset+length and rejects ranges extending
	// beyond the original snapshot before any file bytes are read.
	if offset > before.Size() || length > before.Size()-offset {
		jsonReply(w, http.StatusRequestedRangeNotSatisfiable, map[string]string{"error": "invalid_verification_range"})
		return
	}
	version, ok := fileVersion(before)
	if !ok {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "verification_version_unavailable"})
		return
	}
	if expectedVersion != "" && expectedVersion != version {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "file_changed_during_verification"})
		return
	}

	hasher := sha256.New()
	section := io.NewSectionReader(first, offset, length)
	copied, err := io.CopyBuffer(hasher, contextHashReader{ctx: r.Context(), r: section}, make([]byte, 64*1024))
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return
		}
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "verification_read_failed"})
		return
	}
	if copied != length || r.Context().Err() != nil {
		if r.Context().Err() != nil {
			return
		}
		jsonReply(w, http.StatusConflict, map[string]string{"error": "file_changed_during_verification"})
		return
	}
	changed, statErr := first.Stat()
	changedVersion, changedVersionOK := fileVersion(changed)
	if statErr != nil || !changedVersionOK || !os.SameFile(before, changed) || changedVersion != version {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "file_changed_during_verification"})
		return
	}
	latest, latestInfo, err := a.files.Read(name)
	if err != nil {
		fileError(w, err)
		return
	}
	latest.Close()
	latestVersion, latestVersionOK := fileVersion(latestInfo)
	if !latestVersionOK || !os.SameFile(before, latestInfo) || latestVersion != version {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "file_changed_during_verification"})
		return
	}
	// Recheck the caller's current read authorization immediately before a
	// successful range response as grants can change while hashing.
	if !a.allowFile(w, r, name, false) {
		return
	}
	if r.Context().Err() != nil {
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"algorithm": "sha256",
		"sha256":    hex.EncodeToString(hasher.Sum(nil)),
		"size":      before.Size(),
		"offset":    offset,
		"length":    copied,
		"version":   version,
	})
}

func parseNonNegativeInt64(raw string) (int64, bool) {
	if raw == "" || strings.TrimSpace(raw) != raw {
		return 0, false
	}
	for _, char := range raw {
		if char < '0' || char > '9' {
			return 0, false
		}
	}
	value, err := strconv.ParseInt(raw, 10, 64)
	return value, err == nil
}

// fileVersion is an opaque token bound to a physical object and its change
// generation. Access time is intentionally excluded because reading a file
// may update it. The path and raw filesystem identity never leave this hash.
func fileVersion(info os.FileInfo) (string, bool) {
	if info == nil || info.Sys() == nil {
		return "", false
	}
	stat := reflect.ValueOf(info.Sys())
	for stat.Kind() == reflect.Pointer || stat.Kind() == reflect.Interface {
		if stat.IsNil() {
			return "", false
		}
		stat = stat.Elem()
	}
	if stat.Kind() != reflect.Struct {
		return "", false
	}
	dev, devOK := statIdentityField(stat, "Dev", "VolumeSerialNumber")
	ino, inoOK := statIdentityField(stat, "Ino", "FileIndex")
	ctime, ctimeOK := statIdentityField(stat, "Ctim", "Ctimespec", "ChangeTime")
	if !devOK || !inoOK || !ctimeOK {
		return "", false
	}
	birth, _ := statIdentityField(stat, "Birthtimespec", "BirthTime", "Btim")
	generation, _ := statIdentityField(stat, "Gen", "Generation")
	metadata := fmt.Sprintf("%s|%s|%s|%d|%d|%d", stat.Type().String(), dev, ino,
		info.Size(), info.ModTime().UnixNano(), info.Mode())
	metadata += "|ctime:" + ctime + "|birth:" + birth + "|generation:" + generation
	sum := sha256.Sum256([]byte(metadata))
	return hex.EncodeToString(sum[:]), true
}

func statIdentityField(stat reflect.Value, names ...string) (string, bool) {
	for _, name := range names {
		field := stat.FieldByName(name)
		if !field.IsValid() || !field.CanInterface() {
			continue
		}
		return fmt.Sprintf("%v", field.Interface()), true
	}
	return "", false
}
