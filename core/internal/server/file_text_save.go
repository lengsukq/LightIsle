package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/lengsukq/lightisle/core/internal/files"
)

const maxEditableTextBytes = 2 << 20 // 2 MiB

var editableTextExtensions = map[string]bool{
	".md": true, ".markdown": true, ".txt": true,
	".json": true, ".yaml": true, ".yml": true, ".toml": true,
	".ini": true, ".conf": true, ".cfg": true, ".properties": true,
	".csv": true, ".tsv": true, ".log": true, ".xml": true,
	".sql": true, ".srt": true, ".vtt": true,
	".env": true, ".gitignore": true,
	".css": true, ".js": true, ".ts": true, ".html": true, ".htm": true,
	".sh": true, ".py": true, ".go": true, ".dart": true,
	".swift": true, ".kt": true, ".java": true, ".rs": true,
	".c": true, ".h": true, ".cpp": true, ".hpp": true,
}

func isEditableTextPath(relPath string) bool {
	ext := strings.ToLower(filepath.Ext(relPath))
	return editableTextExtensions[ext]
}

// fileTextGet returns UTF-8 text content alongside its exact nanosecond
// mtimeUnixNano so Web/Flutter editors can submit optimistic concurrency locks
// via PUT /files/text without 1-second HTTP Last-Modified truncation.
func (a *API) fileTextGet(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	cleanPath := cleanClientRelativePath(r.URL.Query().Get("path"))
	if cleanPath == "" {
		writeAPIErrorCode(w, http.StatusBadRequest, "path_not_allowed")
		return
	}
	if !isEditableTextPath(cleanPath) {
		writeAPIErrorCode(w, http.StatusUnsupportedMediaType, "text_edit_unsupported_type")
		return
	}
	if !a.allowFile(w, r, cleanPath, false) {
		return
	}
	f, info, err := a.files.Read(cleanPath)
	if err != nil {
		fileError(w, err)
		return
	}
	defer f.Close()
	if info.Size() > maxEditableTextBytes {
		writeAPIErrorCode(w, http.StatusRequestEntityTooLarge, "text_file_too_large")
		return
	}
	data, err := io.ReadAll(io.LimitReader(f, maxEditableTextBytes+1))
	if err != nil {
		fileError(w, err)
		return
	}
	if len(data) > maxEditableTextBytes {
		writeAPIErrorCode(w, http.StatusRequestEntityTooLarge, "text_file_too_large")
		return
	}
	if !utf8.Valid(data) {
		writeAPIErrorCode(w, http.StatusUnsupportedMediaType, "text_file_invalid_utf8")
		return
	}
	mtimeNano := info.ModTime().UnixNano()
	jsonReply(w, http.StatusOK, map[string]any{
		"path":          cleanPath,
		"name":          info.Name(),
		"content":       string(data),
		"size":          info.Size(),
		"mtimeUnixNano": mtimeNano,
		"mtimeToken":    strconv.FormatInt(mtimeNano, 10),
		"modified":      info.ModTime().UTC().Format("2006-01-02T15:04:05Z07:00"),
		"canWrite":      a.canAccess(token(r), cleanPath, true, false),
	})
}

func (a *API) fileTextSave(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	replacer, ok := a.files.(interface {
		ReplaceTextFile(string, []byte, int64, bool) (files.TextSaveResult, error)
	})
	if !ok {
		a.fileUnavailable(w)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxEditableTextBytes+(64<<10))
	defer r.Body.Close()

	var body struct {
		Path                  string `json:"path"`
		Content               string `json:"content"`
		ExpectedMtimeUnixNano int64  `json:"expectedMtimeUnixNano"`
		ExpectedMtimeToken    string `json:"expectedMtimeToken"`
		Create                bool   `json:"create"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeAPIErrorCode(w, http.StatusRequestEntityTooLarge, "text_file_too_large")
			return
		}
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
		return
	}
	expectedMtime, err := parseExpectedMtime(body.ExpectedMtimeToken, body.ExpectedMtimeUnixNano)
	if err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
		return
	}
	cleanPath := cleanClientRelativePath(body.Path)
	if cleanPath == "" {
		writeAPIErrorCode(w, http.StatusBadRequest, "path_not_allowed")
		return
	}
	if !isEditableTextPath(cleanPath) {
		writeAPIErrorCode(w, http.StatusUnsupportedMediaType, "text_edit_unsupported_type")
		return
	}
	if len(body.Content) > maxEditableTextBytes {
		writeAPIErrorCode(w, http.StatusRequestEntityTooLarge, "text_file_too_large")
		return
	}
	if !utf8.ValidString(body.Content) || strings.ContainsRune(body.Content, 0) {
		writeAPIErrorCode(w, http.StatusBadRequest, "text_file_invalid_utf8")
		return
	}
	if !a.allowFile(w, r, cleanPath, true) {
		return
	}
	if a.rootID != "" && (a.rootLease == nil || a.rootRuntime == nil || !a.rootLease.Valid(r.Context())) {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "root_unavailable")
		return
	}

	// Fast pre-flight optimistic concurrency check before reserving quota.
	if !body.Create {
		existingInfo, statErr := a.files.Stat(cleanPath)
		if statErr != nil {
			fileError(w, statErr)
			return
		}
		if !existingInfo.Mode().IsRegular() {
			writeAPIErrorCode(w, http.StatusBadRequest, "unsupported_file_type")
			return
		}
		if expectedMtime > 0 && existingInfo.ModTime().UnixNano() != expectedMtime {
			writeTextConflict(w, existingInfo)
			return
		}
	}

	payload := []byte(body.Content)
	newSize := int64(len(payload))
	var reservation string
	if a.rootID != "" {
		resID, _, resErr := a.auth.ReserveStorageTextUpdate(token(r), a.rootID, a.rootRuntime.root.Generation, cleanPath, newSize)
		if resErr != nil {
			storageQuotaError(w, resErr)
			return
		}
		reservation = resID
	}

	saved, err := replacer.ReplaceTextFile(cleanPath, payload, expectedMtime, body.Create)
	if err != nil {
		if reservation != "" && !errors.Is(err, files.ErrPublishedSync) {
			_ = a.auth.ReleaseStorageReservation(reservation)
		}
		if errors.Is(err, files.ErrModifiedConflict) {
			writeTextConflict(w, saved.Info)
			return
		}
		fileError(w, err)
		return
	}

	if reservation != "" {
		if a.rootLease == nil || !a.rootLease.Valid(r.Context()) {
			writeAPIErrorCode(w, http.StatusInternalServerError, "storage_accounting_uncertain")
			return
		}
		if err := a.auth.CommitStorageTextUpdate(reservation, newSize, saved.Identity); err != nil {
			writeAPIErrorCode(w, http.StatusInternalServerError, "storage_accounting_uncertain")
			return
		}
	}
	if a.rootID != "" && (a.rootLease == nil || !a.rootLease.Valid(r.Context())) {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "root_unavailable")
		return
	}
	if a.rootServer != nil {
		a.rootServer.QueueMediaRefresh(a.rootID, cleanPath)
	}
	savedMtime := saved.Info.ModTime().UnixNano()
	jsonReply(w, http.StatusOK, map[string]any{
		"saved":         true,
		"path":          cleanPath,
		"size":          saved.Info.Size(),
		"mtimeUnixNano": savedMtime,
		"mtimeToken":    strconv.FormatInt(savedMtime, 10),
		"modified":      saved.Info.ModTime().UTC().Format("2006-01-02T15:04:05Z07:00"),
	})
}

func parseExpectedMtime(tokenStr string, legacyNano int64) (int64, error) {
	if trimmed := strings.TrimSpace(tokenStr); trimmed != "" {
		parsed, err := strconv.ParseInt(trimmed, 10, 64)
		if err != nil || parsed < 0 {
			return 0, errors.New("invalid_expected_mtime_token")
		}
		return parsed, nil
	}
	if legacyNano < 0 {
		return 0, errors.New("invalid_expected_mtime_unix_nano")
	}
	return legacyNano, nil
}

func writeTextConflict(w http.ResponseWriter, info os.FileInfo) {
	safe := true
	resp := map[string]any{
		"error":      "file_modified_conflict",
		"message":    "文件在磁盘上已被其他设备或 Finder 修改，本次保存已中止以防覆盖他人更改。",
		"dataSafe":   &safe,
		"nextAction": "请先保留当前草稿，刷新查看最新版本后再合并保存。",
	}
	if info != nil {
		mtimeNano := info.ModTime().UnixNano()
		resp["currentMtimeUnixNano"] = mtimeNano
		resp["currentMtimeToken"] = strconv.FormatInt(mtimeNano, 10)
		resp["currentSize"] = info.Size()
	}
	jsonReply(w, http.StatusConflict, resp)
}
