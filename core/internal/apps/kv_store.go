package apps

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	kvSubdirName          = "kv"
	maxKVValueBytes       = 512 << 10 // 512 KiB per key
	maxKVKeysPerApp       = 64
	maxKVTotalBytesPerApp = 4 << 20 // 4 MiB total per app
)

// kvKeyPattern permits alphanumeric and leading underscore (e.g. "_reminders")
// followed by up to 63 safe characters. Dot-prefixes and ".." are rejected.
var kvKeyPattern = regexp.MustCompile(`^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,63}$`)

type kvKeyMeta struct {
	Key       string `json:"key"`
	Size      int64  `json:"size"`
	ETag      string `json:"etag"`
	UpdatedAt string `json:"updatedAt"`
}

type kvListResponse struct {
	Keys          []kvKeyMeta `json:"keys"`
	Count         int         `json:"count"`
	TotalBytes    int64       `json:"totalBytes"`
	MaxKeys       int         `json:"maxKeys"`
	MaxTotalBytes int64       `json:"maxTotalBytes"`
	MaxValueBytes int64       `json:"maxValueBytes"`
}

type kvPutResponse struct {
	Key       string `json:"key"`
	Size      int64  `json:"size"`
	ETag      string `json:"etag"`
	UpdatedAt string `json:"updatedAt"`
}

// ValidKVKey validates a static-app KV key name.
func ValidKVKey(key string) bool {
	if !kvKeyPattern.MatchString(key) {
		return false
	}
	return !strings.Contains(key, "..")
}

func kvETag(raw []byte) string {
	sum := sha256.Sum256(raw)
	return fmt.Sprintf(`"%x"`, sum[:16])
}

func kvIfMatchMatches(headerValue, currentETag string) bool {
	if currentETag == "" {
		return false
	}
	for _, raw := range strings.Split(headerValue, ",") {
		cand := strings.TrimSpace(raw)
		if cand == "*" || cand == currentETag {
			return true
		}
	}
	return false
}

func (m *Manager) kvAppLock(appID string) *sync.Mutex {
	m.kvLocksMu.Lock()
	defer m.kvLocksMu.Unlock()
	if m.kvAppLocks == nil {
		m.kvAppLocks = make(map[string]*sync.Mutex)
	}
	mu, ok := m.kvAppLocks[appID]
	if !ok {
		mu = &sync.Mutex{}
		m.kvAppLocks[appID] = mu
	}
	return mu
}

// serveAppKV handles /__lightisle_kv and /__lightisle_kv/{key} requests after
// ServeApp has verified authentication, RBAC access, storage online status, and
// that the app's Web surface is enabled.
func (m *Manager) serveAppKV(w http.ResponseWriter, r *http.Request, rec *appRecord, rest string) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Vary", "Cookie")

	if rest == "/__lightisle_kv" || rest == "/__lightisle_kv/" {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			writeAppError(w, http.StatusMethodNotAllowed, "method_not_allowed", "仅支持 GET 查询存储键列表。")
			return
		}
		m.handleKVList(w, r, rec)
		return
	}

	rawKey := strings.TrimPrefix(rest, "/__lightisle_kv/")
	if !ValidKVKey(rawKey) {
		writeAppError(w, http.StatusBadRequest, "invalid_kv_key", "无效的存储键名（仅允许字母、数字、下划线开头及 . _ -，最长 64 字符）。")
		return
	}

	switch r.Method {
	case http.MethodGet, http.MethodHead:
		m.handleKVGet(w, r, rec, rawKey)
	case http.MethodPut:
		m.handleKVPut(w, r, rec, rawKey)
	case http.MethodDelete:
		m.handleKVDelete(w, r, rec, rawKey)
	default:
		writeAppError(w, http.StatusMethodNotAllowed, "method_not_allowed", "不支持的 HTTP 请求方法。")
	}
}

func openExistingKVRoot(dataDir string) (*os.Root, *os.Root, error) {
	dataRoot, err := os.OpenRoot(dataDir)
	if err != nil {
		return nil, nil, err
	}
	kvRoot, err := dataRoot.OpenRoot(kvSubdirName)
	if err != nil {
		_ = dataRoot.Close()
		return nil, nil, err
	}
	return dataRoot, kvRoot, nil
}

func openKVRootWritable(dataDir string) (*os.Root, *os.Root, error) {
	if err := os.MkdirAll(dataDir, 0700); err != nil {
		return nil, nil, err
	}
	dataRoot, err := os.OpenRoot(dataDir)
	if err != nil {
		return nil, nil, err
	}
	if err := ensureSafeSubdirsInRoot(dataRoot, kvSubdirName); err != nil {
		_ = dataRoot.Close()
		return nil, nil, err
	}
	kvRoot, err := dataRoot.OpenRoot(kvSubdirName)
	if err != nil {
		_ = dataRoot.Close()
		return nil, nil, err
	}
	return dataRoot, kvRoot, nil
}

func (m *Manager) handleKVList(w http.ResponseWriter, r *http.Request, rec *appRecord) {
	mu := m.kvAppLock(rec.id)
	mu.Lock()
	defer mu.Unlock()

	resp := kvListResponse{
		Keys:          []kvKeyMeta{},
		MaxKeys:       maxKVKeysPerApp,
		MaxTotalBytes: maxKVTotalBytesPerApp,
		MaxValueBytes: maxKVValueBytes,
	}

	dataRoot, kvRoot, err := openExistingKVRoot(rec.dataDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			writeKVJSON(w, http.StatusOK, r.Method == http.MethodHead, resp)
			return
		}
		writeAppError(w, http.StatusServiceUnavailable, "kv_storage_unavailable", "无法访问轻应用共享存储目录。")
		return
	}
	defer dataRoot.Close()
	defer kvRoot.Close()

	dir, err := kvRoot.Open(".")
	if err != nil {
		writeAppError(w, http.StatusServiceUnavailable, "kv_storage_unavailable", "无法读取轻应用共享存储目录。")
		return
	}
	entries, err := dir.ReadDir(-1)
	_ = dir.Close()
	if err != nil {
		writeAppError(w, http.StatusServiceUnavailable, "kv_storage_unavailable", "无法列出轻应用共享存储键。")
		return
	}

	for _, entry := range entries {
		name := entry.Name()
		if strings.HasPrefix(name, ".") || !strings.HasSuffix(name, ".json") {
			continue
		}
		key := strings.TrimSuffix(name, ".json")
		if !ValidKVKey(key) {
			continue
		}
		raw, st, readErr := readCheckedFile(kvRoot, name, maxKVValueBytes)
		if readErr != nil {
			continue
		}
		resp.Keys = append(resp.Keys, kvKeyMeta{
			Key:       key,
			Size:      int64(len(raw)),
			ETag:      kvETag(raw),
			UpdatedAt: st.ModTime().UTC().Format(time.RFC3339),
		})
		resp.TotalBytes += int64(len(raw))
	}
	sort.Slice(resp.Keys, func(i, j int) bool { return resp.Keys[i].Key < resp.Keys[j].Key })
	resp.Count = len(resp.Keys)
	writeKVJSON(w, http.StatusOK, r.Method == http.MethodHead, resp)
}

func (m *Manager) handleKVGet(w http.ResponseWriter, r *http.Request, rec *appRecord, key string) {
	mu := m.kvAppLock(rec.id)
	mu.Lock()
	defer mu.Unlock()

	dataRoot, kvRoot, err := openExistingKVRoot(rec.dataDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			writeAppError(w, http.StatusNotFound, "kv_not_found", "指定的共享存储键不存在。")
			return
		}
		writeAppError(w, http.StatusServiceUnavailable, "kv_storage_unavailable", "无法访问轻应用共享存储目录。")
		return
	}
	defer dataRoot.Close()
	defer kvRoot.Close()

	raw, _, err := readCheckedFile(kvRoot, key+".json", maxKVValueBytes)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			writeAppError(w, http.StatusNotFound, "kv_not_found", "指定的共享存储键不存在。")
			return
		}
		writeAppError(w, http.StatusInternalServerError, "kv_read_failed", "读取共享存储数据失败。")
		return
	}

	etag := kvETag(raw)
	w.Header().Set("ETag", etag)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if appIfNoneMatchContains(r.Header.Get("If-None-Match"), etag) {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		_, _ = w.Write(raw)
	}
}

func (m *Manager) handleKVPut(w http.ResponseWriter, r *http.Request, rec *appRecord, key string) {
	if strings.TrimSpace(r.Header.Get("X-LightIsle-Request")) != "1" {
		writeAppError(w, http.StatusForbidden, "csrf_header_required", "缺少安全请求头 X-LightIsle-Request: 1。")
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, maxKVValueBytes+1))
	if err != nil {
		writeAppError(w, http.StatusBadRequest, "kv_body_read_failed", "读取请求内容失败。")
		return
	}
	if int64(len(body)) > maxKVValueBytes {
		writeAppError(w, http.StatusRequestEntityTooLarge, "kv_value_too_large", "单条存储数据不能超过 512 KiB。")
		return
	}
	trimmed := bytes.TrimSpace(body)
	if len(trimmed) == 0 || !json.Valid(trimmed) {
		writeAppError(w, http.StatusBadRequest, "invalid_json", "存储内容必须是合法的 JSON 数据。")
		return
	}

	mu := m.kvAppLock(rec.id)
	mu.Lock()
	defer mu.Unlock()

	dataRoot, kvRoot, err := openKVRootWritable(rec.dataDir)
	if err != nil {
		writeAppError(w, http.StatusServiceUnavailable, "kv_storage_unavailable", "无法打开轻应用共享存储目录。")
		return
	}
	defer dataRoot.Close()
	defer kvRoot.Close()

	filename := key + ".json"
	currentETag, exists, inspectErr := inspectKVFile(kvRoot, filename)
	if inspectErr != nil {
		writeAppError(w, http.StatusBadRequest, "kv_invalid_target", "目标存储文件状态异常，已拒绝覆盖。")
		return
	}

	if ifNoneMatch := strings.TrimSpace(r.Header.Get("If-None-Match")); ifNoneMatch != "" {
		if exists && appIfNoneMatchContains(ifNoneMatch, currentETag) {
			writeKVConflict(w, currentETag)
			return
		}
	}
	if ifMatch := strings.TrimSpace(r.Header.Get("If-Match")); ifMatch != "" {
		if !exists || !kvIfMatchMatches(ifMatch, currentETag) {
			writeKVConflict(w, currentETag)
			return
		}
	}

	otherKeys, otherBytes, scanErr := measureOtherKVUsage(kvRoot, filename)
	if scanErr != nil {
		writeAppError(w, http.StatusInternalServerError, "kv_quota_check_failed", "检查轻应用共享存储配额失败。")
		return
	}
	if otherKeys+1 > maxKVKeysPerApp {
		writeAppError(w, http.StatusRequestEntityTooLarge, "kv_key_limit_exceeded", "当前轻应用存储键数量已达到上限（最多 64 个）。")
		return
	}
	if otherBytes+int64(len(trimmed)) > maxKVTotalBytesPerApp {
		writeAppError(w, http.StatusRequestEntityTooLarge, "kv_quota_exceeded", "当前轻应用共享存储总容量已超过 4 MiB 上限。")
		return
	}

	if err := writeKVFileAtomic(kvRoot, filename, trimmed); err != nil {
		writeAppError(w, http.StatusInternalServerError, "kv_write_failed", "保存共享存储数据失败，请检查磁盘空间与权限。")
		return
	}

	newETag := kvETag(trimmed)
	w.Header().Set("ETag", newETag)
	writeKVJSON(w, http.StatusOK, false, kvPutResponse{
		Key:       key,
		Size:      int64(len(trimmed)),
		ETag:      newETag,
		UpdatedAt: time.Now().UTC().Format(time.RFC3339),
	})
}

func (m *Manager) handleKVDelete(w http.ResponseWriter, r *http.Request, rec *appRecord, key string) {
	if strings.TrimSpace(r.Header.Get("X-LightIsle-Request")) != "1" {
		writeAppError(w, http.StatusForbidden, "csrf_header_required", "缺少安全请求头 X-LightIsle-Request: 1。")
		return
	}

	mu := m.kvAppLock(rec.id)
	mu.Lock()
	defer mu.Unlock()

	ifMatch := strings.TrimSpace(r.Header.Get("If-Match"))
	dataRoot, kvRoot, err := openExistingKVRoot(rec.dataDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			if ifMatch != "" {
				writeKVConflict(w, "")
				return
			}
			writeAppError(w, http.StatusNotFound, "kv_not_found", "指定的共享存储键不存在。")
			return
		}
		writeAppError(w, http.StatusServiceUnavailable, "kv_storage_unavailable", "无法访问轻应用共享存储目录。")
		return
	}
	defer dataRoot.Close()
	defer kvRoot.Close()

	filename := key + ".json"
	currentETag, exists, inspectErr := inspectKVFile(kvRoot, filename)
	if inspectErr != nil {
		writeAppError(w, http.StatusBadRequest, "kv_invalid_target", "目标存储文件状态异常。")
		return
	}
	if !exists {
		if ifMatch != "" {
			writeKVConflict(w, "")
			return
		}
		writeAppError(w, http.StatusNotFound, "kv_not_found", "指定的共享存储键不存在。")
		return
	}
	if ifMatch != "" && !kvIfMatchMatches(ifMatch, currentETag) {
		writeKVConflict(w, currentETag)
		return
	}
	if err := kvRoot.Remove(filename); err != nil {
		writeAppError(w, http.StatusInternalServerError, "kv_delete_failed", "删除共享存储键失败。")
		return
	}
	writeKVJSON(w, http.StatusOK, false, map[string]any{
		"deleted": true,
		"key":     key,
	})
}

func inspectKVFile(kvRoot *os.Root, filename string) (string, bool, error) {
	st, err := kvRoot.Lstat(filename)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", false, nil
		}
		return "", false, err
	}
	if !st.Mode().IsRegular() {
		return "", false, ErrInvalid
	}
	raw, _, err := readCheckedFile(kvRoot, filename, maxKVValueBytes)
	if err != nil {
		return "", false, err
	}
	return kvETag(raw), true, nil
}

func measureOtherKVUsage(kvRoot *os.Root, excludeFilename string) (int, int64, error) {
	dir, err := kvRoot.Open(".")
	if err != nil {
		return 0, 0, err
	}
	entries, err := dir.ReadDir(-1)
	_ = dir.Close()
	if err != nil {
		return 0, 0, err
	}
	count := 0
	var total int64
	for _, entry := range entries {
		name := entry.Name()
		if name == excludeFilename || strings.HasPrefix(name, ".") || !strings.HasSuffix(name, ".json") {
			continue
		}
		if entry.Type()&os.ModeSymlink != 0 || entry.IsDir() {
			continue
		}
		info, statErr := kvRoot.Lstat(name)
		if statErr != nil || !info.Mode().IsRegular() {
			continue
		}
		count++
		total += info.Size()
	}
	return count, total, nil
}

func writeKVFileAtomic(kvRoot *os.Root, filename string, data []byte) error {
	var rnd [8]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		return err
	}
	tmpName := ".kv-tmp-" + hex.EncodeToString(rnd[:])
	f, err := kvRoot.OpenFile(tmpName, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	cleanup := true
	defer func() {
		if cleanup {
			_ = kvRoot.Remove(tmpName)
		}
	}()
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := kvRoot.Rename(tmpName, filename); err != nil {
		return err
	}
	cleanup = false
	if dir, err := kvRoot.Open("."); err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}
	return nil
}

func writeKVConflict(w http.ResponseWriter, currentETag string) {
	if currentETag != "" {
		w.Header().Set("ETag", currentETag)
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusPreconditionFailed)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"error":   "kv_conflict",
		"message": "数据已被其他设备或成员更新，请刷新最新内容后再保存。",
		"etag":    currentETag,
	})
}

func writeKVJSON(w http.ResponseWriter, status int, headOnly bool, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if headOnly {
		return
	}
	_ = json.NewEncoder(w).Encode(payload)
}
