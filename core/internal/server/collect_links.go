package server

import (
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

const (
	collectGrantCookie     = "lightisle_collect_grant"
	collectUploadChunkHint = int64(4) << 20 // 4 MiB recommended chunk size
	collectUploadMaxInMem  = 4096
	collectUploadStaleTTL  = 24 * time.Hour
)

type trackedCollectUpload struct {
	linkDigestHex string
	size          int64
	createdAt     time.Time
}

type collectUploadTracker struct {
	mu      sync.Mutex
	uploads map[string]trackedCollectUpload
}

func newCollectUploadTracker() *collectUploadTracker {
	return &collectUploadTracker{uploads: make(map[string]trackedCollectUpload)}
}

func (t *collectUploadTracker) gcLocked(now time.Time) {
	for id, u := range t.uploads {
		if now.Sub(u.createdAt) > collectUploadStaleTTL {
			delete(t.uploads, id)
		}
	}
}

func (t *collectUploadTracker) tryRegister(uploadID string, linkDigest []byte, size int64, maxFiles int, maxTotalBytes int64, uploadedFiles int, uploadedBytes int64) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := time.Now()
	t.gcLocked(now)
	if len(t.uploads) >= collectUploadMaxInMem {
		return false
	}
	key := hex.EncodeToString(linkDigest)
	var inflightFiles int
	var inflightBytes int64
	for _, u := range t.uploads {
		if u.linkDigestHex == key {
			inflightFiles++
			inflightBytes += u.size
		}
	}
	if maxFiles > 0 && uploadedFiles+inflightFiles >= maxFiles {
		return false
	}
	if maxTotalBytes > 0 && uploadedBytes+inflightBytes+size > maxTotalBytes {
		return false
	}
	t.uploads[uploadID] = trackedCollectUpload{
		linkDigestHex: key,
		size:          size,
		createdAt:     now,
	}
	return true
}

func (t *collectUploadTracker) matches(uploadID string, linkDigest []byte) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	u, ok := t.uploads[uploadID]
	if !ok {
		return false
	}
	expected := hex.EncodeToString(linkDigest)
	return subtle.ConstantTimeCompare([]byte(u.linkDigestHex), []byte(expected)) == 1
}

func (t *collectUploadTracker) remove(uploadID string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.uploads, uploadID)
}

func (t *collectUploadTracker) inflightFor(linkDigest []byte) (int, int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.gcLocked(time.Now())
	key := hex.EncodeToString(linkDigest)
	var count int
	var bytes int64
	for _, u := range t.uploads {
		if u.linkDigestHex == key {
			count++
			bytes += u.size
		}
	}
	return count, bytes
}

// collectPublicHandler acquires the target physical root lease for a write-only
// public collect link without ever consulting root_file_shares.
func collectPublicHandler(base *API, method func(*API) http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s := base.rootServer
		if s == nil || s.registry == nil || base.auth == nil || !s.beginRequest() {
			http.NotFound(w, r)
			return
		}
		var finish sync.Once
		var inUse *rootRuntime
		endRequest := func() {
			finish.Do(func() {
				if inUse != nil {
					s.releaseRuntime(inUse)
				}
				s.requests.Done()
			})
		}
		defer endRequest()

		rootID := r.PathValue("rootID")
		access, err := base.auth.ResolveRootCollectLink(r.PathValue("token"))
		if err != nil || access.RootID != rootID {
			http.NotFound(w, r)
			return
		}
		lease, err := s.registry.Acquire(r.Context(), rootID)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		defer lease.Close()

		runtime, err := s.runtimeFor(r.Context(), rootID, lease)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		inUse = runtime

		access, err = base.auth.ResolveRootCollectLink(r.PathValue("token"))
		if err != nil || access.RootID != rootID || access.RootGeneration != runtime.root.Generation {
			http.NotFound(w, r)
			return
		}
		if !lease.Valid(r.Context()) {
			http.NotFound(w, r)
			return
		}
		child := *base
		child.collector = nil
		child.backup = nil
		child.rootID = rootID
		child.rootLease = lease
		child.rootRuntime = runtime
		child.files = runtime.services.Files
		child.gallery = runtime.services.Gallery
		child.cinema = runtime.services.Cinema
		child.journal = runtime.services.Journal
		method(&child)(w, r)
	}
}

func (a *API) createCollectLink(w http.ResponseWriter, r *http.Request) {
	if a.files == nil || a.rootID == "" || a.rootRuntime == nil {
		a.fileUnavailable(w)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	defer r.Body.Close()

	var body struct {
		Path          string   `json:"path"`
		Hours         int      `json:"hours"`
		Title         string   `json:"title"`
		Password      string   `json:"password"`
		MaxFiles      int      `json:"maxFiles"`
		MaxFileBytes  int64    `json:"maxFileBytes"`
		MaxTotalBytes int64    `json:"maxTotalBytes"`
		AllowedExts   []string `json:"allowedExts"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_collect_link_request")
		return
	}
	cleanPath := cleanClientRelativePath(body.Path)
	if cleanPath == "" || body.Hours < 1 || body.Hours > auth.MaxCollectHours {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_collect_link_request")
		return
	}
	if !a.allowFile(w, r, cleanPath, true) {
		return
	}
	info, err := a.files.Stat(cleanPath)
	if err != nil {
		fileError(w, err)
		return
	}
	if !info.IsDir() {
		writeAPIErrorCode(w, http.StatusBadRequest, "collect_target_must_be_folder")
		return
	}
	dirID, ok := dirFingerprint(info)
	if !ok {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "unsupported_file_identity")
		return
	}
	if body.Password != "" {
		if !allowPasswordWork(w) {
			return
		}
		defer func() { <-passwordWorkSlots }()
	}
	expiresAt := time.Now().Add(time.Duration(body.Hours) * time.Hour).Unix()
	link, capability, err := a.auth.CreateRootCollectLink(
		r.Context(), token(r), a.rootID, a.rootRuntime.root.Generation,
		cleanPath, dirID, expiresAt,
		auth.CollectLinkPolicy{
			Title:         body.Title,
			Password:      body.Password,
			MaxFiles:      body.MaxFiles,
			MaxFileBytes:  body.MaxFileBytes,
			MaxTotalBytes: body.MaxTotalBytes,
			AllowedExts:   body.AllowedExts,
		},
	)
	switch {
	case err == nil:
		jsonReply(w, http.StatusCreated, map[string]any{
			"link":       link,
			"token":      capability,
			"publicPath": "/api/v2/roots/" + a.rootID + "/public/collect/" + capability,
		})
	case errors.Is(err, auth.ErrExists):
		writeAPIErrorCode(w, http.StatusConflict, "too_many_collect_links")
	case errors.Is(err, auth.ErrForbidden):
		writeAPIErrorCode(w, http.StatusForbidden, "file_permission_denied")
	case errors.Is(err, auth.ErrInput):
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_collect_link_request")
	default:
		writeAPIErrorCode(w, http.StatusInternalServerError, "collect_link_creation_failed")
	}
}

func (a *API) listCollectLinks(w http.ResponseWriter, r *http.Request) {
	if a.rootID == "" {
		a.fileUnavailable(w)
		return
	}
	links, err := a.auth.ListRootCollectLinks(token(r), a.rootID)
	if err != nil {
		writeAPIErrorCode(w, http.StatusInternalServerError, "collect_link_list_failed")
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"links": links})
}

func (a *API) revokeCollectLink(w http.ResponseWriter, r *http.Request) {
	if a.rootID == "" {
		a.fileUnavailable(w)
		return
	}
	err := a.auth.RevokeRootCollectLink(r.Context(), token(r), a.rootID, r.PathValue("id"))
	if errors.Is(err, auth.ErrInput) {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_collect_link_id")
		return
	}
	if err != nil {
		writeAPIErrorCode(w, http.StatusInternalServerError, "collect_link_revoke_failed")
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"revoked": true})
}

func (a *API) resolveVerifiedCollectLink(r *http.Request) (auth.CollectLinkAccess, auth.User, bool) {
	if a.files == nil || a.auth == nil || a.rootID == "" || a.rootRuntime == nil {
		return auth.CollectLinkAccess{}, auth.User{}, false
	}
	if a.rootLease == nil || !a.rootLease.Valid(r.Context()) {
		return auth.CollectLinkAccess{}, auth.User{}, false
	}
	access, err := a.auth.ResolveRootCollectLink(r.PathValue("token"))
	if err != nil || access.RootID != a.rootID || access.RootGeneration != a.rootRuntime.root.Generation {
		return auth.CollectLinkAccess{}, auth.User{}, false
	}
	info, err := a.files.Stat(access.TargetPath)
	if err != nil || !info.IsDir() {
		return auth.CollectLinkAccess{}, auth.User{}, false
	}
	dirID, ok := dirFingerprint(info)
	if !ok || dirID != access.DirIdentity {
		return auth.CollectLinkAccess{}, auth.User{}, false
	}
	creator, err := a.auth.GetUser(access.UserID)
	if err != nil || !creator.Enabled {
		return auth.CollectLinkAccess{}, auth.User{}, false
	}
	return access, creator, true
}

func collectGrantValue(r *http.Request) string {
	c, err := r.Cookie(collectGrantCookie)
	if err != nil {
		return ""
	}
	return c.Value
}

func (a *API) collectLinkUnlocked(r *http.Request, access auth.CollectLinkAccess) bool {
	if len(access.PasswordHash) == 0 {
		return true
	}
	return a.collectGrants != nil && a.collectGrants.verify(collectGrantValue(r), access.Digest)
}

func (a *API) publicCollectPage(w http.ResponseWriter, r *http.Request) {
	access, _, ok := a.resolveVerifiedCollectLink(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	unlocked := a.collectLinkUnlocked(r, access)
	inflightFiles, inflightBytes := 0, int64(0)
	if a.collectUploads != nil {
		inflightFiles, inflightBytes = a.collectUploads.inflightFor(access.Digest)
	}
	if r.URL.Query().Get("format") == "json" {
		resp := map[string]any{
			"title":         access.Title,
			"expiresAt":     access.ExpiresAt,
			"hasPassword":   len(access.PasswordHash) > 0,
			"unlocked":      unlocked,
			"maxFiles":      access.MaxFiles,
			"maxFileBytes":  access.MaxFileBytes,
			"maxTotalBytes": access.MaxTotalBytes,
			"uploadedFiles": access.UploadedFiles,
			"uploadedBytes": access.UploadedBytes,
			"allowedExts":   access.AllowedExts,
			"chunkSize":     collectUploadChunkHint,
		}
		if access.MaxFiles > 0 {
			rem := access.MaxFiles - access.UploadedFiles - inflightFiles
			if rem < 0 {
				rem = 0
			}
			resp["remainingFiles"] = rem
		}
		if access.MaxTotalBytes > 0 {
			rem := access.MaxTotalBytes - access.UploadedBytes - inflightBytes
			if rem < 0 {
				rem = 0
			}
			resp["remainingBytes"] = rem
		}
		w.Header().Set("X-Robots-Tag", "noindex,nofollow,noarchive")
		jsonReply(w, http.StatusOK, resp)
		return
	}
	basePath := "/api/v2/roots/" + a.rootID + "/public/collect/" + r.PathValue("token")
	renderCollectDropPage(w, basePath, access, unlocked)
}

func (a *API) publicCollectAuth(w http.ResponseWriter, r *http.Request) {
	access, _, ok := a.resolveVerifiedCollectLink(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	if len(access.PasswordHash) == 0 {
		jsonReply(w, http.StatusOK, map[string]bool{"unlocked": true})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	defer r.Body.Close()
	var body struct {
		Password string `json:"password"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil || body.Password == "" || len(body.Password) > 256 {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
		return
	}
	if !allowPasswordWork(w) {
		return
	}
	defer func() { <-passwordWorkSlots }()

	limitKey := "collect:" + r.PathValue("token")
	if !a.limiter.admit(r.RemoteAddr, limitKey) {
		writeAPIErrorCode(w, http.StatusTooManyRequests, "too_many_attempts")
		return
	}
	if !auth.SharePasswordOK(access.PasswordHash, body.Password) {
		writeAPIErrorCode(w, http.StatusUnauthorized, "collect_password_invalid")
		return
	}
	a.limiter.success(r.RemoteAddr, limitKey)

	grantVal, minted := a.collectGrants.mint(access.Digest)
	if !minted {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "collect_grant_unavailable")
		return
	}
	basePath := "/api/v2/roots/" + a.rootID + "/public/collect/" + r.PathValue("token")
	http.SetCookie(w, &http.Cookie{
		Name:     collectGrantCookie,
		Value:    grantVal,
		Path:     basePath,
		MaxAge:   int(shareGrantLifetime.Seconds()),
		HttpOnly: true,
		Secure:   secureCookieRequest(r),
		SameSite: http.SameSiteLaxMode,
	})
	jsonReply(w, http.StatusOK, map[string]bool{"unlocked": true})
}

func sanitizeCollectFilename(raw string) (string, bool) {
	name := strings.TrimSpace(raw)
	if name == "" || name == "." || name == ".." || len(name) > 240 {
		return "", false
	}
	if strings.ContainsAny(name, "/\\\x00") {
		return "", false
	}
	if files.IsInternalName(name) || files.IsSystemMetadataName(name) {
		return "", false
	}
	return name, true
}

func collectExtensionAllowed(filename string, allowedExts []string) bool {
	if len(allowedExts) == 0 {
		return true
	}
	ext := strings.ToLower(filepath.Ext(filename))
	if ext == "" {
		return false
	}
	for _, a := range allowedExts {
		if ext == a {
			return true
		}
	}
	return false
}

func (a *API) publicCollectUploadBegin(w http.ResponseWriter, r *http.Request) {
	access, creator, ok := a.resolveVerifiedCollectLink(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	if !a.collectLinkUnlocked(r, access) {
		writeAPIErrorCode(w, http.StatusUnauthorized, "collect_auth_required")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	defer r.Body.Close()
	var req struct {
		Filename string `json:"filename"`
		Size     int64  `json:"size"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
		return
	}
	cleanName, validName := sanitizeCollectFilename(req.Filename)
	if !validName || req.Size < 0 || req.Size > auth.MaxCollectSingleFileBytes {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_collect_upload")
		return
	}
	if !collectExtensionAllowed(cleanName, access.AllowedExts) {
		writeAPIErrorCode(w, http.StatusUnsupportedMediaType, "collect_extension_not_allowed")
		return
	}
	if access.MaxFileBytes > 0 && req.Size > access.MaxFileBytes {
		writeAPIErrorCode(w, http.StatusRequestEntityTooLarge, "collect_file_too_large")
		return
	}
	if access.MaxFiles > 0 && access.UploadedFiles >= access.MaxFiles {
		writeAPIErrorCode(w, http.StatusConflict, "collect_limit_reached")
		return
	}
	if access.MaxTotalBytes > 0 && access.UploadedBytes+req.Size > access.MaxTotalBytes {
		writeAPIErrorCode(w, http.StatusConflict, "collect_limit_reached")
		return
	}

	gen := a.rootRuntime.root.Generation
	baseDest := path.Join(access.TargetPath, cleanName)
	destination := baseDest

	for attempt := 0; attempt <= 1000; attempt++ {
		if a.rootLease == nil || !a.rootLease.Valid(r.Context()) {
			writeAPIErrorCode(w, http.StatusServiceUnavailable, "root_unavailable")
			return
		}
		resID, _, resErr := a.auth.ReserveStorageUploadForUser(creator, a.rootID, gen, destination, req.Size)
		if resErr != nil {
			if errors.Is(resErr, auth.ErrStorageLedgerConflict) {
				next, candErr := files.NextRenameCandidate(baseDest, attempt+2)
				if candErr != nil {
					fileError(w, candErr)
					return
				}
				destination = next
				continue
			}
			storageQuotaError(w, resErr)
			return
		}
		upload, upErr := a.files.BeginUpload(destination, req.Size, creator.ID)
		if upErr == nil {
			if resID != "" {
				if linkErr := a.auth.LinkStorageUpload(resID, upload.ID); linkErr != nil {
					a.rollbackUnlinkedCollectUpload(r, upload.ID, creator.ID, resID, destination, req.Size)
					writeAPIErrorCode(w, http.StatusServiceUnavailable, "upload_begin_uncertain")
					return
				}
			}
			if !a.collectUploads.tryRegister(upload.ID, access.Digest, req.Size, access.MaxFiles, access.MaxTotalBytes, access.UploadedFiles, access.UploadedBytes) {
				a.abortCollectStaging(r, upload.ID, creator.ID)
				writeAPIErrorCode(w, http.StatusConflict, "collect_limit_reached")
				return
			}
			jsonReply(w, http.StatusCreated, map[string]any{
				"uploadId":  upload.ID,
				"offset":    upload.Offset,
				"size":      upload.Size,
				"chunkSize": collectUploadChunkHint,
			})
			return
		}
		if errors.Is(upErr, files.ErrUploadBeginUncertain) || !a.rootLease.Valid(r.Context()) {
			writeAPIErrorCode(w, http.StatusServiceUnavailable, "upload_begin_uncertain")
			return
		}
		if resID != "" {
			if a.auth.ReleaseUnlinkedStorageReservation(resID, a.rootID, gen, destination, req.Size) != nil {
				writeAPIErrorCode(w, http.StatusServiceUnavailable, "upload_begin_uncertain")
				return
			}
		}
		if !errors.Is(upErr, files.ErrExists) {
			fileError(w, upErr)
			return
		}
		next, candErr := files.NextRenameCandidate(baseDest, attempt+2)
		if candErr != nil {
			fileError(w, candErr)
			return
		}
		destination = next
	}
	writeAPIErrorCode(w, http.StatusConflict, "file_already_exists")
}

func (a *API) rollbackUnlinkedCollectUpload(r *http.Request, uploadID string, owner int64, resID, destination string, size int64) {
	guarded, ok := a.files.(interface {
		AbortUploadWithAccounting(string, int64) (bool, error)
	})
	if !ok {
		return
	}
	safe, abortErr := guarded.AbortUploadWithAccounting(uploadID, owner)
	_, statErr := a.files.Stat(destination)
	if abortErr == nil && safe && errors.Is(statErr, fs.ErrNotExist) &&
		a.rootLease != nil && a.rootLease.Valid(r.Context()) {
		_ = a.auth.ReleaseUnlinkedStorageReservation(resID, a.rootID, a.rootRuntime.root.Generation, destination, size)
	}
}

func (a *API) abortCollectStaging(r *http.Request, uploadID string, owner int64) {
	release := false
	var err error
	if guarded, ok := a.files.(interface {
		AbortUploadWithAccounting(string, int64) (bool, error)
	}); ok {
		release, err = guarded.AbortUploadWithAccounting(uploadID, owner)
	} else {
		err = a.files.AbortUpload(uploadID, owner)
	}
	if err == nil {
		_ = a.releaseRemovedUploadReservation(r, uploadID, release)
	}
}

func (a *API) publicCollectUploadChunk(w http.ResponseWriter, r *http.Request) {
	access, creator, ok := a.resolveVerifiedCollectLink(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	if !a.collectLinkUnlocked(r, access) {
		writeAPIErrorCode(w, http.StatusUnauthorized, "collect_auth_required")
		return
	}
	uploadID := r.PathValue("uploadID")
	if a.collectUploads == nil || !a.collectUploads.matches(uploadID, access.Digest) {
		http.NotFound(w, r)
		return
	}
	if r.ContentLength < 0 || r.ContentLength > 8<<20 {
		writeAPIErrorCode(w, http.StatusRequestEntityTooLarge, "invalid_chunk_size")
		return
	}
	offset, err := strconv.ParseInt(r.Header.Get("X-Upload-Offset"), 10, 64)
	if err != nil || offset < 0 {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_offset")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, (8<<20)+1)
	defer r.Body.Close()
	body, admitted := admitFileUpload(w, r.Body)
	if !admitted {
		return
	}
	defer func() { <-fileUploadSlots }()

	current, err := a.files.UploadInfo(uploadID, creator.ID)
	if err != nil {
		fileError(w, err)
		return
	}
	if path.Dir(current.Path) != access.TargetPath {
		http.NotFound(w, r)
		return
	}
	if managedStorageName(current.Path) {
		if _, err := a.auth.ReservationForRootUploadForUser(uploadID, creator, a.rootID, a.rootRuntime.root.Generation, current.Path); err != nil {
			storageQuotaError(w, err)
			return
		}
	}
	state, err := a.files.AppendUpload(uploadID, creator.ID, offset, body)
	if errors.Is(err, files.ErrOffset) {
		w.Header().Set("X-Upload-Offset", strconv.FormatInt(state.Offset, 10))
		jsonReply(w, http.StatusConflict, map[string]any{"error": "offset_mismatch", "offset": state.Offset})
		return
	}
	if err != nil {
		uploadStreamError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"uploadId": state.ID,
		"offset":   state.Offset,
		"size":     state.Size,
	})
}

func (a *API) publicCollectUploadComplete(w http.ResponseWriter, r *http.Request) {
	access, creator, ok := a.resolveVerifiedCollectLink(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	if !a.collectLinkUnlocked(r, access) {
		writeAPIErrorCode(w, http.StatusUnauthorized, "collect_auth_required")
		return
	}
	uploadID := r.PathValue("uploadID")
	if a.collectUploads == nil || !a.collectUploads.matches(uploadID, access.Digest) {
		http.NotFound(w, r)
		return
	}
	current, err := a.files.UploadInfo(uploadID, creator.ID)
	if err != nil {
		fileError(w, err)
		return
	}
	if path.Dir(current.Path) != access.TargetPath {
		http.NotFound(w, r)
		return
	}
	var reservation string
	if managedStorageName(current.Path) {
		reservation, err = a.auth.ReservationForRootUploadForUser(uploadID, creator, a.rootID, a.rootRuntime.root.Generation, current.Path)
		if err != nil {
			storageQuotaError(w, err)
			return
		}
	}

	if err := a.auth.ConsumeRootCollectUpload(access.Digest, current.Size); err != nil {
		if errors.Is(err, auth.ErrCollectLimitReached) {
			a.collectUploads.remove(uploadID)
			a.abortCollectStaging(r, uploadID, creator.ID)
			writeAPIErrorCode(w, http.StatusConflict, "collect_limit_reached")
			return
		}
		http.NotFound(w, r)
		return
	}

	var identity string
	if guarded, ok := a.files.(interface {
		FinishUploadWithIdentity(string, int64) (string, error)
	}); ok && reservation != "" {
		identity, err = guarded.FinishUploadWithIdentity(uploadID, creator.ID)
	} else {
		err = a.files.FinishUpload(uploadID, creator.ID)
	}
	if err != nil {
		if !errors.Is(err, files.ErrPublishedSync) {
			_ = a.auth.RefundRootCollectUpload(access.Digest, current.Size)
		}
		fileError(w, err)
		return
	}
	a.collectUploads.remove(uploadID)

	if reservation != "" {
		if a.rootLease == nil || !a.rootLease.Valid(r.Context()) {
			writeAPIErrorCode(w, http.StatusInternalServerError, "storage_accounting_uncertain")
			return
		}
		if err := a.auth.CommitStorageReservationWithIdentity(reservation, identity); err != nil {
			writeAPIErrorCode(w, http.StatusInternalServerError, "storage_accounting_uncertain")
			return
		}
	}
	if a.rootLease == nil || !a.rootLease.Valid(r.Context()) {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "root_unavailable")
		return
	}
	a.recordAudit(access.UserID, "public_collect_upload", "collect_link", "success")
	if a.rootServer != nil {
		a.rootServer.QueueMediaRefresh(a.rootID, current.Path)
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"completed": true,
		"size":      current.Size,
	})
}

func (a *API) publicCollectUploadAbort(w http.ResponseWriter, r *http.Request) {
	access, creator, ok := a.resolveVerifiedCollectLink(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	if !a.collectLinkUnlocked(r, access) {
		writeAPIErrorCode(w, http.StatusUnauthorized, "collect_auth_required")
		return
	}
	uploadID := r.PathValue("uploadID")
	if a.collectUploads == nil || !a.collectUploads.matches(uploadID, access.Digest) {
		http.NotFound(w, r)
		return
	}
	a.collectUploads.remove(uploadID)
	a.abortCollectStaging(r, uploadID, creator.ID)
	jsonReply(w, http.StatusOK, map[string]bool{"cancelled": true})
}
